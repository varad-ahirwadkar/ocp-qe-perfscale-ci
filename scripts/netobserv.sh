#!/usr/bin/env bash

SCRIPTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
export DEFAULT_SC=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

deploy_netobserv() {
  echo "====> Deploying NetObserv"
  if [[ -z $INSTALLATION_SOURCE ]]; then
    echo "Please set INSTALLATION_SOURCE env variable to either 'Official', 'Internal', 'OperatorHub', or 'Source' if you intend to use the 'deploy_netobserv' function"
    echo "Don't forget to source 'netobserv.sh' again after doing so!"
    exit 1
  elif [[ $INSTALLATION_SOURCE == "Official" ]]; then
    echo "Using 'Official' as INSTALLATION_SOURCE"
    NOO_SUBSCRIPTION=netobserv-official-subscription.yaml
  elif [[ $INSTALLATION_SOURCE == "Internal" ]]; then
    echo "Using 'Internal' as INSTALLATION_SOURCE"
    NOO_SUBSCRIPTION=netobserv-internal-subscription.yaml
    deploy_unreleased_catalogsource
  elif [[ $INSTALLATION_SOURCE == "OperatorHub" ]]; then
    echo "Using 'OperatorHub' as INSTALLATION_SOURCE"
    NOO_SUBSCRIPTION=netobserv-operatorhub-subscription.yaml
  elif [[ $INSTALLATION_SOURCE == "Source" ]]; then
    echo "Using 'Source' as INSTALLATION_SOURCE"
    NOO_SUBSCRIPTION=netobserv-source-subscription.yaml
    deploy_main_catalogsource
  else
    echo "'$INSTALLATION_SOURCE' is not a valid value for INSTALLATION_SOURCE"
    echo "Please set INSTALLATION_SOURCE env variable to either 'Official', 'Internal', 'OperatorHub', or 'Source' if you intend to use the 'deploy_netobserv' function"
    echo "Don't forget to source 'netobserv.sh' again after doing so!"
    exit 1
  fi

  echo "====> Creating NetObserv Project (if it does not already exist)"
  oc new-project netobserv || true

  echo "====> Checking if LokiStack prerequisite has been satisfied"
  oc wait --timeout=300s --for=condition=ready pod -l app.kubernetes.io/name=lokistack -n netobserv

  echo "====> Adding RBACs for authToken FORWARD"
  oc apply -f $SCRIPTS_DIR/netobserv/clusterRoleBinding-FORWARD.yaml

  echo "====> Creating openshift-netobserv-operator namespace and OperatorGroup"
  oc apply -f $SCRIPTS_DIR/netobserv/netobserv-ns_og.yaml
  echo "====> Creating NetObserv subscription"
  oc apply -f $SCRIPTS_DIR/netobserv/$NOO_SUBSCRIPTION
  sleep 60
  oc wait --timeout=180s --for=condition=ready pod -l app=netobserv-operator -n openshift-netobserv-operator
  while :; do
    oc get crd/flowcollectors.flows.netobserv.io && break
    sleep 1
  done

  echo "====> Creating Flow Collector"
  oc apply -f $SCRIPTS_DIR/netobserv/flows_v1beta1_flowcollector.yaml

  echo "====> Waiting for flowlogs-pipeline pods to be ready"
  while :; do
    oc get daemonset flowlogs-pipeline -n netobserv && break
    sleep 1
  done
  sleep 60
  oc wait --timeout=1200s --for=condition=ready pod -l app=flowlogs-pipeline -n netobserv
}

deploy_lokistack() {
  echo "====> Deploying LokiStack"
  echo "====> Creating NetObserv Project (if it does not already exist)"
  oc new-project netobserv || true

  echo "====> Creating openshift-operators-redhat Namespace and OperatorGroup"
  oc apply -f $SCRIPTS_DIR/loki/loki-operatorgroup.yaml

  echo "====> Creating qe-unreleased-testing CatalogSource (if applicable) and Loki Operator Subscription"
  if [[ $LOKI_OPERATOR == "Released" ]]; then
    oc apply -f $SCRIPTS_DIR/loki/loki-released-subscription.yaml
  elif [[ $LOKI_OPERATOR == "Unreleased" ]]; then
    deploy_unreleased_catalogsource
    oc apply -f $SCRIPTS_DIR/loki/loki-unreleased-subscription.yaml
  else
    echo "====> No Loki Operator config was found - using Released"
    echo "====> To set config, set LOKI_OPERATOR variable to either 'Released' or 'Unreleased'"
    oc apply -f $SCRIPTS_DIR/loki/loki-released-subscription.yaml
  fi

  echo "====> Generate S3_BUCKETNAME"
  RAND_SUFFIX=$(tr </dev/urandom -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
  if [[ $WORKLOAD == "None" ]] || [[ -z $WORKLOAD ]]; then
    export S3_BUCKETNAME="netobserv-ocpqe-$USER-$RAND_SUFFIX"
  else
    export S3_BUCKETNAME="netobserv-ocpqe-$USER-$WORKLOAD-$RAND_SUFFIX"
  fi

  # if cluster is to be preserved, do the same for S3 bucket
  CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
  if [[ $CLUSTER_NAME =~ "preserve" ]]; then
    S3_BUCKETNAME+="-preserve"
  fi
  echo "====> S3_BUCKETNAME is $S3_BUCKETNAME"

  echo "====> Creating S3 secret for Loki"
  $SCRIPTS_DIR/deploy-loki-aws-secret.sh $S3_BUCKETNAME
  sleep 60
  oc wait --timeout=180s --for=condition=ready pod -l app.kubernetes.io/name=loki-operator -n openshift-operators-redhat

  echo "====> Determining LokiStack config"
  if [[ $LOKISTACK_SIZE == "1x.extra-small" ]]; then
    LokiStack_CONFIG=$SCRIPTS_DIR/loki/lokistack-1x-exsmall.yaml
  elif [[ $LOKISTACK_SIZE == "1x.small" ]]; then
    LokiStack_CONFIG=$SCRIPTS_DIR/loki/lokistack-1x-small.yaml
  elif [[ $LOKISTACK_SIZE == "1x.medium" ]]; then
    LokiStack_CONFIG=$SCRIPTS_DIR/loki/lokistack-1x-medium.yaml
  else
    echo "====> No LokiStack config was found - using 1x.extra-small"
    echo "====> To set config, set LOKISTACK_SIZE variable to either '1x.extra-small', '1x.small', or '1x.medium'"
    LokiStack_CONFIG=$SCRIPTS_DIR/loki/lokistack-1x-exsmall.yaml
  fi
  TMP_LOKICONFIG=/tmp/lokiconfig.yaml
  envsubst <$LokiStack_CONFIG >$TMP_LOKICONFIG

  echo "====> Creating LokiStack"
  oc apply -f $TMP_LOKICONFIG
  sleep 30
  oc wait --timeout=300s --for=condition=ready pod -l app.kubernetes.io/name=lokistack -n netobserv

  echo "====> Configuring Loki rate limit alert"
  oc apply -f $SCRIPTS_DIR/loki/loki-ratelimit-alert.yaml
}

deploy_unreleased_catalogsource() {
  echo "====> Creating brew-registry ImageContentSourcePolicy"
  oc apply -f $SCRIPTS_DIR/icsp.yaml

  echo "====> Determining CatalogSource config"
  if [[ -z $IMAGE ]]; then
    echo "====> No image config was found - cannot create CatalogSource"
    echo "====> To set config, set IMAGE variable to desired endpoint"
    exit 1
  else
    echo "====> Using image $IMAGE for CatalogSource"
  fi

  CatalogSource_CONFIG=$SCRIPTS_DIR/catalogsources/qe-unreleased-catalogsource.yaml
  TMP_CATALOGCONFIG=/tmp/catalogconfig.yaml
  envsubst <$CatalogSource_CONFIG >$TMP_CATALOGCONFIG

  echo "====> Creating qe-unreleased-testing CatalogSource"
  oc apply -f $TMP_CATALOGCONFIG
  sleep 30
  oc wait --timeout=180s --for=condition=ready pod -l olm.catalogSource=qe-unreleased-testing -n openshift-marketplace
}

deploy_main_catalogsource() {
  echo "====> Creating netobserv-main-testing CatalogSource from the main bundle"
  oc apply -f $SCRIPTS_DIR/catalogsources/netobserv-main-catalogsource.yaml
  sleep 30
  oc wait --timeout=180s --for=condition=ready pod -l olm.catalogSource=netobserv-main-testing -n openshift-marketplace
}

deploy_loki() {
  echo "====> Deploying Loki"
  oc apply -f $SCRIPTS_DIR/loki/loki-storage-1.yaml
  oc apply -f $SCRIPTS_DIR/loki/loki-storage-2.yaml
  oc wait --timeout=120s --for=condition=ready pod -l app=loki -n netobserv
}

deploy_kafka() {
  echo "====> Deploying Kafka"
  oc create namespace netobserv --dry-run=client -o yaml | oc apply -f -
  echo "====> Creating amq-streams Subscription"
  oc apply -f $SCRIPTS_DIR/amq-streams/amq-streams-subscription.yaml
  sleep 60
  oc wait --timeout=180s --for=condition=ready pod -l name=amq-streams-cluster-operator -n openshift-operators
  echo "====> Creating kafka-metrics ConfigMap and kafka-resources-metrics PodMonitor"
  oc apply -f "https://raw.githubusercontent.com/netobserv/documents/main/examples/kafka/metrics-config.yaml" -n netobserv
  echo "====> Creating kafka-cluster Kafka"
  curl -s -L "https://raw.githubusercontent.com/netobserv/documents/main/examples/kafka/default.yaml" | envsubst | oc apply -n netobserv -f -

  echo "====> Creating network-flows KafkaTopic"
  if [[ -z $TOPIC_PARTITIONS ]]; then
    echo "====> No topic partitions config was found - using 6"
    echo "====> To set config, set TOPIC_PARTITIONS variable to desired number"
    export TOPIC_PARTITIONS=6
  fi  
  KAFKA_TOPIC=$SCRIPTS_DIR/amq-streams/kafkaTopic.yaml
  TMP_KAFKA_TOPIC=/tmp/topic.yaml
  envsubst <$KAFKA_TOPIC >$TMP_KAFKA_TOPIC
  oc apply -f $TMP_KAFKA_TOPIC -n netobserv
  sleep 60
  oc wait --timeout=180s --for=condition=ready kafkatopic network-flows -n netobserv

  echo "====> Update flowcollector to use KAFKA deploymentModel"
  oc patch flowcollector cluster --type=json -p "[{"op": "replace", "path": "/spec/deploymentModel", "value": "KAFKA"}]"

  echo "====> Update flowcollector replicas"
  if [[ -z $FLP_KAFKA_REPLICAS ]]; then
    echo "====> No flowcollector replicas config was found - using 3"
    echo "====> To set config, set FLP_KAFKA_REPLICAS variable to desired number"
    FLP_KAFKA_REPLICAS=3
  fi
  oc patch flowcollector/cluster --type=json -p "[{"op": "replace", "path": "/spec/processor/kafkaConsumerReplicas", "value": $FLP_KAFKA_REPLICAS}]"

  echo "====> Update ClusterRoleBinding ServiceAccount from flowlogs-pipeline to flowlogs-pipeline-transformer"
  oc apply -f $SCRIPTS_DIR/netobserv/clusterRoleBinding-FORWARD-kafka.yaml

  oc wait --timeout=180s --for=condition=ready flowcollector/cluster
}

populate_netobserv_metrics() {
  echo "====> Creating cluster-monitoring-config ConfigMap"
  oc apply -f $SCRIPTS_DIR/cluster-monitoring-config.yaml
  DEPLOYMENT_MODEL=$(oc get flowcollector -o jsonpath='{.items[*].spec.deploymentModel}' -n netobserv)
  if [[ $DEPLOYMENT_MODEL == "KAFKA" ]]; then
    echo "====> Creating flowlogs-pipeline-transformer Service and ServiceMonitor"
    oc apply -f $SCRIPTS_DIR/service-monitor-kafka.yaml
  else
    echo "====> Creating flowlogs-pipeline Service and ServiceMonitor"
    oc apply -f $SCRIPTS_DIR/service-monitor.yaml
  fi
}

setup_dittybopper_template() {
  echo "====> Checking NetObserv installation..."
  IS_DOWNSTREAM=$(oc get pods -l app=netobserv-operator -o jsonpath='{.items[*].spec.containers[0].env[-2].value}' -A)
  if [[ $IS_DOWNSTREAM == "true" ]]; then
    echo "===> Downstream installation was detected - no custom Dittybopper template is needed"
  else
    echo "====> Setting up dittybopper template"
    sleep 30
    oc wait --timeout=120s --for=condition=ready pod -n openshift-user-workload-monitoring -l app.kubernetes.io/component=controller
    oc wait --timeout=120s --for=condition=ready pod -n openshift-user-workload-monitoring -l app.kubernetes.io/managed-by=prometheus-operator
    export PROMETHEUS_USER_WORKLOAD_BEARER=$(oc sa get-token prometheus-user-workload -n openshift-user-workload-monitoring || oc sa new-token prometheus-user-workload -n openshift-user-workload-monitoring)
    export THANOS_URL=https://$(oc get route thanos-querier -n openshift-monitoring -o json | jq -r '.spec.host')
    envsubst "$PROMETHEUS_USER_WORKLOAD_BEARER $THANOS_URL" <$SCRIPTS_DIR/netobserv/netobserv-dittybopper.yaml.template >$SCRIPTS_DIR/netobserv/netobserv-dittybopper.yaml
  fi
}

delete_s3() {
  echo "====> Getting S3 Bucket Name"
  S3_BUCKET_NAME=$(/bin/bash -c 'oc extract cm/lokistack-config -n netobserv --keys=config.yaml --confirm --to=/tmp | xargs -I {} egrep bucketnames {} | cut -d: -f 2 | xargs echo -n')
  if [[ -n $S3_BUCKET_NAME ]]; then
    echo "====> Got $S3_BUCKET_NAME"
    echo "====> Deleting AWS S3 Bucket"
    while :; do
      aws s3 rb s3://$S3_BUCKET_NAME --force && break
      sleep 1
    done
    echo "====> AWS S3 Bucket $S3_BUCKET_NAME deleted"
  fi
}

delete_lokistack() {
  echo "====> Deleting LokiStack"
  oc delete --ignore-not-found lokistack/lokistack -n netobserv
}

delete_kafka() {
  echo "====> Deleting Kafka (if applicable)"
  echo "====> Getting Deployment Model"
  DEPLOYMENT_MODEL=$(oc get flowcollector -o jsonpath='{.items[*].spec.deploymentModel}' -n netobserv)
  echo "====> Got $DEPLOYMENT_MODEL"
  if [[ $DEPLOYMENT_MODEL == "KAFKA" ]]; then
    oc delete kafka/kafka-cluster -n netobserv
    oc delete kafkaTopic/network-flows -n netobserv
    oc delete --ignore-not-found -f $SCRIPTS_DIR/amq-streams/amq-streams-subscription.yaml
    oc delete csv -l operators.coreos.com/amq-streams.openshift-operators -n openshift-operators
  fi
}

delete_flowcollector() {
  echo "====> Deleting Flow Collector"
  # note 'cluster' is the default Flow Collector name, but that may not always be the case
  oc delete --ignore-not-found flowcollector/cluster
}

delete_netobserv() {
  echo "====> Deleting all NetObserv resources"
  oc delete --ignore-not-found -f $SCRIPTS_DIR/netobserv/netobserv-official-subscription.yaml
  oc delete --ignore-not-found -f $SCRIPTS_DIR/netobserv/netobserv-internal-subscription.yaml
  oc delete --ignore-not-found -f $SCRIPTS_DIR/netobserv/netobserv-operatorhub-subscription.yaml
  oc delete --ignore-not-found -f $SCRIPTS_DIR/netobserv/netobserv-source-subscription.yaml
  oc delete --ignore-not-found csv -l operators.coreos.com/netobserv-operator.openshift-netobserv-operator= -n openshift-netobserv-operator
  oc delete crd/flowcollectors.flows.netobserv.io
  oc delete --ignore-not-found -f $SCRIPTS_DIR/netobserv/netobserv-ns_og.yaml
  oc delete project netobserv
  echo "====> Deleting netobserv-main-testing and qe-unreleased-testing CatalogSource (if applicable)"
  oc delete --ignore-not-found catalogsource/netobserv-main-testing -n openshift-marketplace
  oc delete --ignore-not-found catalogsource/qe-unreleased-testing -n openshift-marketplace
}

delete_loki_operator() {
  echo "====> Deleting Loki Operator Subscription and CSV"
  oc delete --ignore-not-found -f $SCRIPTS_DIR/loki/loki-released-subscription.yaml
  oc delete --ignore-not-found -f $SCRIPTS_DIR/loki/loki-unreleased-subscription.yaml
  oc delete csv -l operators.coreos.com/loki-operator.openshift-operators-redhat -n openshift-operators-redhat
}

nukeobserv() {
  echo "====> Nuking NetObserv and all related resources"
  delete_s3
  delete_lokistack
  delete_kafka
  delete_flowcollector
  delete_netobserv
  delete_loki_operator
}
