#!/bin/bash

#Libra automated experiments
#
#How to use:
#1: Set the parameters for the next experiment
#2: Call function start_experiment()
#
#Set comma seperated key-value pairs in 'cfg_override_params' variable
#to override Libra default config parameters
#Eg: cfg_override_params='genesis_file_location="genesis2.blob",max_block_size=250,shared_mempool_tick_interval_ms=50,capacity_per_user=1000'

function set_default_parameters() {
    nodes="4"
    image_node0="libra_validator_dynamic:latest"
    image_node1="libra_validator_dynamic:latest"
    cfg_override_params="capacity_per_user=10000"
    cluster_config="1,1,2 500 10:30:40,30:15:50,40:50:12"

    workers_per_account="3"
    accounts_per_client="50"
    throughput="300"
    duration="60"
    step_size_throughput="10"
    step_size_duration="10"
    max_cpu_usage="0"

    only_keep_merged_logs="1"

    experiment_location="jp"

    if [ "$experiment_location" = "jp" ]
    then
        base_directory="/home/jeanpierre/LibraMetrics/containersMetricsFiles"
        log_save_location="$base_directory"

        mint_file_location="$HOME/libra2/libra2/mint.key"
    elif [ "$experiment_location" = "server" ]
    then
        base_directory="/datadrive/libra2/experiments_logs"
        log_save_location="$base_directory"

        mint_file_location="/datadrive/libra2/mint.key"
    fi 
}
set_default_parameters

#Start Libra
function start_libra() {
    ./docker/validator-dynamic/run.sh $nodes $cfg_override_params $image_node0 $image_node1 &

#Returns a list of $ip:$port with length $nodes
#Eg: "localhost:8080,localhost:8081", when $nodes=2
function get_nodes_ips_ports() {
    local peers=""
    local port=8080
    local i=0
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

#This function runs untill Libra is healthy and accepts txns
function wait_for_libra_to_be_ready() {
    cargo run -p cluster-test -- \
    --mint-file "$mint_file_location" \
    --swarm \
    --peers $(get_nodes_ips_ports) \
    --diag

    while [ $? != "0" ]
    do
        IFS=$'\n'
        declare -a containers=($(docker ps -f "ancestor=libra_validator_dynamic" -q))
        IFS=$' '
        if [ ${#containers[@]} != $nodes ]
        then
            echo "A CONTAINER CRASHED AND STOPPED"
            stop_libra_and_delete_containers
            return 1
        fi
        sleep 5
        cargo run -p cluster-test -- \
        --mint-file "$mint_file_location" \
        --swarm \
        --peers $(get_nodes_ips_ports) \
        --diag
    done
}

#Punts #nodes in #clusters based on cluster frequencies
#Eg: 100 0.3316 0.4998 0.0090 0.1177 0.0224 0.0195
#meaning, distribute 100 nodes in 6 clusters with given frequencies
function devide_nodes_between_clusters() {
    declare -a rel_freq_array=(${@:2})
    declare -a result=""

    local count="1"
    local acumulative="0"
    local i=0
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

#Specify clusters and ping between each pair of clusters
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

function get_pings_between_clusters_2() {
    #       NA  EU   SA   ASIA JAPAN AUS
    #NA:    32, 124, 184, 198, 151, 189
    #EU:   124,  11, 227, 237, 252, 294
    #SA:   184, 227,  88, 325, 301, 322
    #ASIA: 198, 237, 325,  85,  58, 198
    #JAPAN:151, 252, 301,  58,  12, 126
    #AUS:  189, 294, 322, 198, 126,  16
    
    NA="10:10:10:10:10:10"
    EU="10:10:10:10:10:10"
    SA="10:10:10:10:10:10"
    ASIA="300:300:300:300:300:300"
    JAPAN="10:10:10:10:10:10"
    AUS="10:10:10:10:10:10"
    pings="$NA,$EU,$SA,$ASIA,$JAPAN,$AUS"

    echo $pings
}

#Put nodes into clusters based on $cluster_config
function put_nodes_into_clusters() {
    source put-containers-in-clusters-generic.sh $cluster_config
    if [ $? != "0" ]
    then
        stop_libra_and_delete_containers
        return 1
    fi
}

#Starts the txns generator
function start_txns_generator() {
    cargo run -p cluster-test -- \
    --mint-file "$mint_file_location" \
    --swarm \
    --peers $(get_nodes_ips_ports) \
    --emit-tx \
    --workers-per-ac $workers_per_account \
    --accounts-per-client $accounts_per_client \
    --burst \
    --throughput $throughput \
    --duration $duration \
    --max-cpu-usage $max_cpu_usage \
    --step-size-throughput $step_size_throughput \
    --step-size-duration $step_size_duration
}

#Copy logs from the containers to host
function copy_logs_from_containers() {
    source copy-logs-from-containers.sh $log_save_location $only_keep_merged_logs
}

#When the experiment is finished, stop Libra and delete containers
#This currently kills all running containers
function stop_libra_and_delete_containers() {
    IFS=$'\n'
    docker container kill $(docker container ls -q)
    IFS=$' '
    docker container prune -f
}

#Specify the order of a single experiment
function start_experiment() {
    start_libra
    sleep $(($nodes*3))
    put_nodes_into_clusters
    if [ $? != "0" ]
    then
        return 1
    fi
    wait_for_libra_to_be_ready
    if [ $? != "0" ]
    then
        return 1
    fi
    start_txns_generator
    sleep 3
    copy_logs_from_containers
    stop_libra_and_delete_containers
}

function experiment_1() {
    #Data used for calculating the impact the number of nodes has on the maximum throughput.
    num_rounds="1"
    #num_nodes=(2 5 8 11 14 17)
    num_nodes=(2 5)
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    #start_throughput=(500 400 300 200 100 100)
    start_throughput=(500 400)

    cfg_override_params="capacity_per_user=10000"
    duration="60"
    step_size_throughput="2"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#num_nodes[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            nodes=${num_nodes[$i_counter]}
            cluster_config="$nodes 500 50"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment1/${num_nodes[$i_counter]}_nodes"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function experiment_2() {
    #Data used for finding out how network delays impact the throughput and transaction delay
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    #delays=(10 30 50 70 90 110 130 150)
    delays=(10 150)
    throughput="500"
    
    cfg_override_params="capacity_per_user=10000"
    duration="60"
    step_size_throughput="2"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#delays[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes 500 ${delays[$i_counter]}"
            log_save_location="$base_directory/Experiment2/${delays[$i_counter]}_delay"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function experiment_3() {
    #Data used for finding out how bandwidth affects the transaction throughput
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    bandwidth=(10 30 50 70 90 110 130 150 170 190 210 230 250)
    bandwidth=(10 150)
    start_throughput="400"
    
    cfg_override_params="capacity_per_user=10000"
    duration="60"
    step_size_throughput="2"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#bandwidth[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes ${bandwidth[$j_counter]} 50"
            throughput=$start_throughput
            log_save_location="$base_directory/Experiment3/${bandwidth[$i_counter]}_bandwidth"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function experiment_4() {
    #Data used for calibrating the Libra simulator
    num_rounds="1"
    nodes="6"
    image_node0="libra_validator_dynamic:latest"
    image_node1="libra_validator_dynamic:latest"
    tick_interval=(150)

    start_throughput="300"
    duration="60"
    step_size_throughput="10"
    step_size_duration="1"
    max_cpu_usage="99"

    for (( i_counter=0; i_counter<${#tick_interval[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes 500 50"
            throughput="$start_throughput"
            log_save_location="$base_directory/Experiment4/${tick_interval[$i_counter]}_tick_interval"
            cfg_override_params="capacity_per_user=10000,shared_mempool_tick_interval_ms=${tick_interval[$i_counter]}"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function test_experiment() {
    for (( i_counter=3; i_counter<=3; i_counter++ ))
    do
        nodes=$i_counter
        #tick_interval=$((50 + $i_counter * 50))
        #tick_interval="50"
        #cfg_override_params="shared_mempool_tick_interval_ms=$tick_interval"
        cfg_override_params="capacity_per_user=10000"
        #cluster_config="$(devide_nodes_between_clusters $nodes 0.3316 0.4998 0.0090 0.1177 0.0224 0.0195) 500 $(get_pings_between_clusters)"
        cluster_config="$nodes 500 50"

        throughput="500"
        duration="300"
        step_size_throughput="10"
        step_size_duration="1"

        log_save_location="$base_directory"

        sleep 2

        start_experiment
        while [ $? != "0" ]
        do
            start_experiment
        done
    done
}

experiment_4
echo "Experiments finished!"