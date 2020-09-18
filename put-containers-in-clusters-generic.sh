#!/bin/bash
#Arg1 = #clusters and #nodes in each cluster
#Arg2 = Throughput for each node(mbit)
#Arg3 = Latency between clusters(ms)

#Example inputs:
#2,3,1 500 10:30:40,30:15:50,40:50:12
#2,3,1 100,200,300,400,500,600 10:30:40,30:15:50,40:50:12

#Parse the arguments
#Put the nodes in clusters
IFS=$','
read -a param1 <<< $1
read -a param2 <<< $2
read -a param3 <<< $3

#specify #nodes and #clusters
nodes="$((${param1[@]/%/+}0))"
clusters=${#param1[@]}

#specify to which cluster each node belongs
declare -a clusters_nodes

for (( i=0; i<$clusters; i++ ))
do
    for (( j=0; j<${param1[i]}; j++ ))
    do
        clusters_nodes+=($i)
    done
done

#specify the throughput for each node
#nodes_throughput=(500mbit 500mbit 500mbit 500mbit)
declare -a nodes_throughput

if [ ${#param2[@]} -eq 1 ]
then
    for (( i=0; i<$nodes; i++ ))
    do
        nodes_throughput+=(${param2}mbit)
    done
else
    for (( i=0; i<${#param2[@]}; i++ ))
    do
        nodes_throughput+=(${param2[i]}mbit)
    done
fi

declare -A clusters_pings
#specify pings between clusters and within a cluster
#(10 30 40)
#(30 15 50)
#(40 50 12)
IFS=$':'
for (( i=0; i<${#param3[@]}; i++ ))
do
    read -a cluster_delay <<< ${param3[i]}
    for (( j=0; j<${#cluster_delay[@]}; j++ ))
    do
        clusters_pings+=([${i},${j}]=${cluster_delay[j]})
    done
done

IFS=$'\n'
counter=0
declare -a containers=($(docker ps -f "ancestor=libra_validator_dynamic" -q))
declare -a containers_2=($(docker ps -f "ancestor=libra_validator_dynamic_perf_node0" -q))
containers=(${containers[@]} ${containers_2[@]})
#echo ${containers[@]}
while [ $nodes -ne ${#containers[@]} ]
do
    if [ $counter -gt 5 ]
    then
        echo "ERROR: $nodes node(s) are specified, but ${#containers[@]} node(s) are running"
        echo "EXIT program"
        exit 1
    fi
    echo "ERROR: $nodes node(s) are specified, but ${#containers[@]} node(s) are running"
    sleep 5
    containers=($(docker ps -f "ancestor=libra_validator_dynamic" -q))
    counter=$((counter+1))
done

if [ ${#clusters_nodes[@]} -ne $nodes ]
then
    echo "ERROR: Not every node is put in a cluster"
    echo "EXIT program"
    exit 1
fi

if [ ${#nodes_throughput[@]} -ne $nodes ]
then
    echo "ERROR: Set the throughput for each node"
    echo "EXIT program"
    exit 1
fi

IFS=$' '
for (( i=0; i<$nodes; i++ ))
do
    #Delete any existent traffic shaping rules
    command="docker exec -it ${containers[$i]} tc qdisc delete dev eth0 root"
    echo $command
    $command

    #Add a HTB classifier
    command="docker exec -it ${containers[$i]} tc qdisc add dev eth0 root handle 1: htb"
    echo $command
    $command

    #Add exactly 1 class per region
    for (( region_id=1; region_id<=$clusters; region_id++ ))
    do
        command="docker exec -it ${containers[$i]} tc class add dev eth0 parent 1: classid 1:$region_id htb rate ${nodes_throughput[i]}"
        echo $command
        $command
    done

    #For each peer IP add it to the correct class
    for (( j=0; j<$nodes; j++ ))
    do
        if [ $i -eq $j ]
            then continue
        fi
        command="docker exec -it ${containers[$i]} tc filter add dev eth0 parent 1: protocol ip prio 1 u32 flowid 1:${clusters_nodes[$j]} match ip dst 172.18.0.$((j+10))"
        echo $command
        $command
    done

    #Specify the ping to each class(cluster)
    for (( region_id=1; region_id<=$clusters; region_id++ ))
    do
        cluster_key="${clusters_nodes[$i]},$((region_id-1))"
        command="docker exec -it ${containers[$i]} tc qdisc add dev eth0 parent 1:$region_id handle ${region_id}0: netem delay ${clusters_pings[$cluster_key]}ms"
        echo $command
        $command
    done
done

echo ${containers[@]} > containers_id.txt