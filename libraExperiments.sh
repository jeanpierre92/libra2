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
    RANDOM=640
    nodes="5"
    image_node0="libra_validator_dynamic:latest"
    image_node1="libra_validator_dynamic:latest"
    cfg_override_params="capacity_per_user=10000"
    cluster_config="1,1,2 500 10:30:40,30:15:50,40:50:12"

    workers_per_ac="3"
    accounts_per_client="80"
    throughput="300"
    duration="300"
    step_size_throughput="1"
    step_size_duration="10"
    max_cpu_usage="0"
    sending_interval_duration="0.3"

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
}

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
        declare -a containers_1=($(docker ps -f "ancestor=libra_validator_dynamic_perf_node0" -q))
        declare -a containers_2=($(docker ps -f "ancestor=libra_validator_dynamic_perf_node1" -q))
        containers=(${containers[@]} ${containers_1[@]} ${containers_2[@]})
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

function get_cluster_config() {
    num_nodes=$1
    ping_mean=$2
    max_ping_distance=$3

    #ping_mean <= random_number <= ping_mean + max_ping_distance 
    declare -A ping_array
    for (( i_counter=0; i_counter<$num_nodes; i_counter++ ));
    do
        for (( j_counter=$i_counter; j_counter<$num_nodes; j_counter++ ));
        do
            random_number=$(( ($RANDOM % ($max_ping_distance+1)) + $ping_mean ))
            ping_array[$i_counter,$j_counter]=$random_number
            #echo "${ping_array[$i_counter,$j_counter]}"
        done
    done

    for (( i_counter=1; i_counter<$num_nodes; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$i_counter; j_counter++ ));
        do
            ping_array[$i_counter,$j_counter]=${ping_array[$j_counter,$i_counter]}
        done
    done

    ping_string=""
    for (( i_counter=0; i_counter<$num_nodes; i_counter++ ));
    do
        ping_string="$ping_string,"
        for (( j_counter=0; j_counter<$num_nodes; j_counter++ ));
        do
            if [ ${ping_string: -1} = "," ]
            then
                ping_string="$ping_string${ping_array[$i_counter,$j_counter]}"
                continue
            fi
            ping_string="$ping_string:${ping_array[$i_counter,$j_counter]}"
        done
    done

    nodes_in_each_cluster=""
    for (( j_counter=0; j_counter<$num_nodes; j_counter++ ));
    do
        nodes_in_each_cluster="$nodes_in_each_cluster,1"
    done

    result_string="${nodes_in_each_cluster:1} 500 ${ping_string:1}"
    echo $result_string
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
    if [ $nodes -lt 3 ] #2 nodes
    then
        workers_per_ac="8"
    elif [ $nodes -lt 4 ] #3 nodes
    then
        workers_per_ac="5"
    elif [ $nodes -lt 5 ] #4 nodes
    then
        workers_per_ac="4"
    elif [ $nodes -lt 6 ] #5 nodes
    then
        workers_per_ac="3"
    elif [ $nodes -lt 7 ] #6 nodes
    then
        workers_per_ac="2"
    elif [ $nodes -lt 8 ] #7 nodes
    then
        workers_per_ac="2"
    elif [ $nodes -lt 9 ] #8 nodes
    then
        workers_per_ac="2"
    else
        workers_per_ac="1"
    fi

    cargo run -p cluster-test -- \
    --mint-file "$mint_file_location" \
    --swarm \
    --peers $(get_nodes_ips_ports) \
    --emit-tx \
    --workers-per-ac $workers_per_ac \
    --accounts-per-client $accounts_per_client \
    --burst \
    --throughput $throughput \
    --duration $duration \
    --max-cpu-usage $max_cpu_usage \
    --step-size-throughput $step_size_throughput \
    --step-size-duration $step_size_duration \
    --sending-interval-duration $sending_interval_duration
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
    only_keep_merged_logs="1"
    num_rounds="1"
    
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    #Sensing:
    #start_throughput=(900 850 800 750 650 500 450 450 400 350 350 300 250 250 200 200)
    #Constant:
    num_nodes=(2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17)
    start_throughput=(1290 1150 1000 900 790 680 610 545 515 480 450 430 380 360 335 325)

    cfg_override_params="capacity_per_user=10000"
    duration="600"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#num_nodes[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            nodes=${num_nodes[$i_counter]}
            cluster_config="$nodes 500 50 10"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment1_constant/${num_nodes[$i_counter]}_nodes"

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
    only_keep_merged_logs="1"
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    delays=(10 30 50 70 90 110 130 150 170 190 210 230 250)
    start_throughput=(900 866 850 850 825 800 777 767 750 740 730 720 708)
    #throughput="300"
    
    cfg_override_params="capacity_per_user=10000"
    duration="400"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#delays[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes 500 ${delays[$i_counter]}"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment2_constant/${delays[$i_counter]}_delay"

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
    only_keep_merged_logs="1"
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    bandwidth=(10 20 30 40 50 60 70 80 90 100 200 300 400 500)
    #bandwidth=(100 200 500)
    start_throughput=(484 664 724 772 791 792 795 800 803 805 836 843 840 840)
    
    cfg_override_params="capacity_per_user=10000"
    duration="400"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#bandwidth[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes ${bandwidth[$i_counter]} 50"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment3_contant/${bandwidth[$i_counter]}_bandwidth"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function experiment_4() {
    #Data used for finding out how the maximum blocksize affects the transaction throughput
    only_keep_merged_logs="1"
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    #throughput="50"
    max_block_size=(100 200 300 400 500 600 700 800 900 1000 1500 2000)
    start_throughput=(257 411 540 650 733 760 785 800 830 866 914 927)

    duration="400"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#max_block_size[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes 500 50"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment4_constant/${max_block_size[$i_counter]}_blocksize"
            cfg_override_params="capacity_per_user=10000,max_block_size=${max_block_size[$i_counter]}"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function experiment_5() {
    #Data used for calibrating the Libra simulator
    #num_rounds="8"
    num_rounds="1"
    nodes="5"
    image_node0="libra_validator_dynamic:latest"
    image_node1="libra_validator_dynamic:latest"
    ping=(50)
    start_throughput=(870)
    #ping=(50 100 150 200 250 300 350 400 400 400)
    #start_throughput=(200 200 200 200 100 100 100 100 100)
    duration="1800"
    step_size_throughput="0"
    step_size_duration="1"
    max_cpu_usage="0"
    sending_interval_duration="1.0"
    only_keep_merged_logs="0"

    for (( i_counter=0; i_counter<${#ping[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            cluster_config="$nodes 500 ${ping[$i_counter]}"
            throughput="${start_throughput[$i_counter]}"
            log_save_location="$base_directory/Experiment5_high_load_calibration/${ping[$i_counter]}_ping"
            cfg_override_params="capacity_per_user=10000"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function vary_sending_interval() {
    #Data used for finding out how the maximum blocksize affects the transaction throughput
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    only_keep_merged_logs="1"

    num_rounds="1"
    num_nodes=(3)

    #start_throughput=(1250 1100 800 660 550 510 450 420 400)
    #start_throughput=(1300 1030 830 700 640 560 500 450 430)
    start_throughput=(1200)
    #sending_interval=(0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1)
    sending_interval=(0.5)

    duration="300"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#num_nodes[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<${#sending_interval[@]}; j_counter++ ));
        do
            for (( k_counter=0; k_counter<$num_rounds; k_counter++ ));
            do
                sending_interval_duration="${sending_interval[$j_counter]}"
                throughput="${start_throughput[$i_counter]}"
                nodes="${num_nodes[$i_counter]}"
                cluster_config="$(get_cluster_config "$nodes" "50" "10")"
                log_save_location="$base_directory/Experiment_vary_sending_interval/${num_nodes[$i_counter]}_nodes/${sending_interval[$j_counter]}_interval"
                cfg_override_params="capacity_per_user=10000"

                start_experiment
                while [ $? != "0" ]
                do
                    start_experiment
                done
            done
        done
    done
}

function test_experiment() {
    for (( i_counter=2; i_counter<=2; i_counter++ ))
    do
        image_node0="libra_validator_dynamic:latest"
        image_node1="libra_validator_dynamic:latest"
        
        only_keep_merged_logs="1"
        nodes=$i_counter

        sending_interval_duration="0.2"
        throughput="1450"
        duration="150"

        cluster_config="$(get_cluster_config "$nodes" "50" "10")"
        log_save_location="$base_directory/Experiment_test/${nodes}_nodes"
        cfg_override_params="capacity_per_user=10000"
        
        step_size_throughput="0"
        step_size_duration="1"

        start_experiment
        while [ $? != "0" ]
        do
            start_experiment
        done
    done
}

test_experiment
echo "Experiments finished!"