#!/bin/bash
#RANDOM=640; 
num_nodes=3
ping_mean=50
max_ping_distance=10

result_string=""

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
        #echo "${ping_array[$i_counter,$j_counter]}"
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