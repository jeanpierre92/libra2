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

    experiment_location="server"

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
    throughput=$4

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

    result_string="${nodes_in_each_cluster:1} $throughput ${ping_string:1}"
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
    sending_interval=(0.1 0.1 0.1 0.2 0.3 0.4 0.4 0.3 0.3 0.3 0.3 0.3 0.3 0.3 0.3)
    #start_throughput=(1255 1170 1090 970 890 800 770 740 720 660 610 580 540 525 490 455)
    #start_throughput=(1200 1100 1030 970 900 810 770 740 700 650 620 600 550 520 500 430)
    #start_throughput=(1170 1080 1050 980 920 850 780 760 720 670 630 610 565 530 500 420)
    start_throughput=(1190 1100 1060 990 915 845 775 765 715 675 635 605 565 525 505 415)
    #                   2   3     4   5   6   7   8   9   10  11  12  13  14  15  16  17

    cfg_override_params="capacity_per_user=10000"
    duration="360"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#num_nodes[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            nodes=${num_nodes[$i_counter]}
            cluster_config="$(get_cluster_config "$nodes" "50" "10" "500")"
            sending_interval_duration="${sending_interval[$i_counter]}"
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment1_constant/attempt3/${num_nodes[$i_counter]}_nodes"

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
    #start_throughput=(970 935 918 918 891 864 839 830 810 800 788 777 764)
    #start_throughput=(1030 970 950 950 930 900 860 850 840 810 790 785 770)
    #start_throughput=(1050 1000 980 960 940 910 880 865 850 820 800 790 770)
    start_throughput=(1050 1010 990 970 950 920 890 870 855 825 805 790 770)
    #                 10   30   50  70  90  110 130 150 170 190 210 230 250

    sending_interval_duration="0.15"
    cfg_override_params="capacity_per_user=10000"
    duration="360"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#delays[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            throughput=${start_throughput[$i_counter]}
            cluster_config="$(get_cluster_config "$nodes" "${delays[$i_counter]}" "10" "500")"
            log_save_location="$base_directory/Experiment2_constant/attempt3/${delays[$i_counter]}_delay"

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
    #start_throughput=(484 664 724 772 791 792 795 800 803 805 836 843 840 840)
    #start_throughput=(700 800 850 900 900 900 910 920 930 935 940 950 960 970)
    #start_throughput=(760 860 900 930 940 940 950 950 950 960 970 980 990 1000)
    start_throughput=(770 875 920 940 950 950 955 960 965 965 970 990 1000 1010)
    #                  10  20  30  40  50  60  70  80  90  100 200 300 400 500

    cfg_override_params="capacity_per_user=10000"
    duration="360"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#bandwidth[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            throughput=${start_throughput[$i_counter]}
            cluster_config="$(get_cluster_config "$nodes" "50" "10" "${bandwidth[$i_counter]}")"
            log_save_location="$base_directory/Experiment3_constant/attempt3/${bandwidth[$i_counter]}_bandwidth"

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

    max_block_size=(100 200 300 400 500 600 700 800 900 1000 1500 2000)
    #start_throughput=(257 411 540 650 733 760 785 800 830 866 914 927)
    #start_throughput=(750 770 800 830 850 860 870 900 930 970 1000 1050)
    #start_throughput=(350 550 650 780 830 865 885 920 950 990 1070 1100)
    start_throughput=(330 500 645 760 825 870 900 960 990 1000 1080 1130)
    #                 100 200 300 400 500 600 700 800 900 1000 1500 2000

    cluster_config="$(get_cluster_config "$nodes" "50" "10" "500")"

    sending_interval_duration="0.15"
    duration="360"
    step_size_throughput="0"
    step_size_duration="1"

    for (( i_counter=0; i_counter<${#max_block_size[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            throughput=${start_throughput[$i_counter]}
            log_save_location="$base_directory/Experiment4_constant/attempt3/${max_block_size[$i_counter]}_blocksize"
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
    sending_interval_duration="0.3"
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

function experiment_compare_swarm_and_simulator() {
    #Data used for comparing Libra Swarm agains the simulator
    image_node0="libra_validator_dynamic:latest"
    image_node1="libra_validator_dynamic:latest"
    num_rounds="1"
    attempt_name="attempt_test"

    #num_nodes=(2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17)
    num_nodes=(9)
    #start_throughput=(1230 1145 1060 960 840 785 730 705 680)
    #start_throughput=(1200 1150 1070 1000 900 820 750 730 700 11 12 13 14 15 16 17)
    #start_throughput=(1210 1150 1060 980 900 830 760 740 710 640 625 610 545 515 510 400)
    start_throughput=(800)
    #sending_interval=(0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.35 0.3 0.3 0.3 0.3 0.3 0.3 0.3 0.3)
    sending_interval=(0.35)
    
    duration="180"

    step_size_throughput="0"
    step_size_duration="1"

    #This determined how quickly a timeout round is generated, Default:1000ms
    round_initial_timeout="10000"
    max_cpu_usage="0"
    only_keep_merged_logs="1"

    for (( i_counter=0; i_counter<${#num_nodes[@]}; i_counter++ ));
    do
        for (( j_counter=0; j_counter<$num_rounds; j_counter++ ));
        do
            nodes=${num_nodes[$i_counter]}
            sending_interval_duration="${sending_interval[$i_counter]}"
            cluster_config="$(get_cluster_config "${num_nodes[$i_counter]}" "50" "10" "500")"
            throughput="${start_throughput[$i_counter]}"
            log_save_location="$base_directory/Experiment_compare_swarm_and_simulator/$attempt_name/${num_nodes[$i_counter]}_nodes"
            cfg_override_params="capacity_per_user=10000,round_initial_timeout_ms=$round_initial_timeout"

            start_experiment
            while [ $? != "0" ]
            do
                start_experiment
            done
        done
    done
}

function vary_sending_interval() {
    #Data used for finding out how sending_txns_interval affects the throughput
    image_node0="libra_validator_dynamic_perf_node0:latest"
    image_node1="libra_validator_dynamic_perf_node1:latest"
    only_keep_merged_logs="1"

    num_rounds="1"
    num_nodes=(3)

    #attempt_1_start_throughput=(1250 1100 800 660 550 510 450 420 400)
    #attempt_2_start_throughput=(1300 1030 830 700 640 560 500 450 430)
    #attempt_3_start_throughput=(1330 980 820 690 655 565 500 440 400)
    #attempt_4_start_throughput=(1200 1030 840 710 670 575 500 460 420)
    start_throughput=(1250 1080 860 750 700 600 550 500 450)
    sending_interval=(0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0)
    #sending_interval=(0.4)

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
                cluster_config="$(get_cluster_config "$nodes" "50" "10" "500")"
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
    for (( i_counter=5; i_counter<=5; i_counter++ ))
    do
        image_node0="libra_validator_dynamic:latest"
        image_node1="libra_validator_dynamic:latest"
        
        only_keep_merged_logs="1"
        nodes=$i_counter

        sending_interval_duration="0.25"
        throughput="900"
        duration="300"

        cluster_config="$(get_cluster_config "$nodes" "50" "10" "500")"
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

experiment_1
experiment_2
experiment_3
experiment_4
echo "Experiments finished!"