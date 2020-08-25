#!/bin/bash

function set_default_parameters() {
    nodes="4"
    cfg_override_params=''
    cluster_config="1,1,2 500 10:30:40,30:15:50,40:50:12"

    workers_per_account="1"
    accounts_per_client="10"
    throughput="300"
    duration="60"
    step_size_throughput="10"
    step_size_duration="10"

    log_save_location="/home/jeanpierre/LibraMetrics/containersMetricsFiles"
    only_keep_merged_logs="1"
}
set_default_parameters

function start_libra() {
    ./docker/validator-dynamic/run.sh $nodes $cfg_override_params &
}

function get_nodes_ips_ports() {
    local peers=""
    local port=8080
    for (( i=0; i<$nodes; i++ ))
    do
        if (( $i > 0 ))
        then
            peers="${peers},"
        fi
        peers="${peers}localhost:$port"
        port=$(($port + 1))
    done
    echo $peers
}

function wait_for_libra_to_be_ready() {
    cargo run -p cluster-test -- \
    --mint-file "$HOME/libra2/libra2/mint.key" \
    --swarm \
    --peers $(get_nodes_ips_ports) \
    --diag
}

function devide_nodes_between_clusters() {
    #rel_freq_array=(0.3316 0.4998 0.0090 0.1177 0.0224 0.0195)
    declare -a rel_freq_array=(${@:2})
    declare -a result=""

    count="1"
    acumulative="0"
    for (( i=0; i<${#rel_freq_array[@]}; i++ ))
    do
        acumulative=$(echo "$acumulative+${rel_freq_array[i]}" | bc -l)
        temp="0"
        max=$(echo "scale=0;($1*$acumulative+0.99999999) / 1" | bc -l)

        for (( j=$count; j<=$max; j++ ))
        do
            ((temp=temp+1))
            ((count=count+1))
        done

        if [ $i -gt 0 ]
        then
            result="$result,"
        fi
        result="${result}${temp}"
    done

    echo $result
}

function get_pings_between_clusters() {
    #       NA  EU   SA   ASIA JAPAN AUS
    #NA:    32, 124, 184, 198, 151, 189
    #EU:   124,  11, 227, 237, 252, 294
    #SA:   184, 227,  88, 325, 301, 322
    #ASIA: 198, 237, 325,  85,  58, 198
    #JAPAN:151, 252, 301,  58,  12, 126
    #AUS:  189, 294, 322, 198, 126,  16
    
    NA="32:124:184:198:151:189"
    EU="124:11:227:237:252:294"
    SA="184:227:88:325:301:322"
    ASIA="198:237:325:85:58:198"
    JAPAN="151:252:301:58:12:126"
    AUS="189:294:322:198:126:16"
    pings="$NA,$EU,$SA,$ASIA,$JAPAN,$AUS"

    echo $pings
}

function put_nodes_into_clusters() {
    source put-containers-in-clusters-generic.sh $cluster_config
}

function start_txns_generator() {
    cargo run -p cluster-test -- \
    --mint-file "$HOME/libra2/libra2/mint.key" \
    --swarm \
    --peers $(get_nodes_ips_ports) \
    --emit-tx \
    --workers-per-ac $workers_per_account \
    --accounts-per-client $accounts_per_client \
    --burst \
    --throughput $throughput \
    --duration $duration \
    --step-size-throughput $step_size_throughput \
    --step-size-duration $step_size_duration
}

function copy_logs_from_containers() {
    source copy-logs-from-containers.sh $log_save_location $only_keep_merged_logs
}

function stop_libra_and_delete_containers() {
    IFS=$'\n'
    docker container kill $(docker container ls -q)
    IFS=$' '
    docker container prune -f
}

function start_experiment() {
    start_libra
    sleep 8
    wait_for_libra_to_be_ready
    put_nodes_into_clusters
    start_txns_generator
    sleep 3
    copy_logs_from_containers
    stop_libra_and_delete_containers
}

for (( i=3; i<=15; i++ ))
do
    nodes=$i
    cluster_config="$(devide_nodes_between_clusters $i 0.3316 0.4998 0.0090 0.1177 0.0224 0.0195) 500 $(get_pings_between_clusters)"

    throughput="100"
    duration="10"
    step_size_throughput="10"
    step_size_duration="10"

    log_save_location="/home/jeanpierre/LibraMetrics/containersMetricsFiles/experiment1"

    start_experiment
done

echo "Experiments finished!"