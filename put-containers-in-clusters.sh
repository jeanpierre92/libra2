#!/bin/bash

#Specify #nodes and #clusters
nodes=8
clusters=3

#to which cluster each node belongs
#each entry should be < #clusters
clusters_nodes=(0 0 1 1 2 2 2 2)

#specify the throughput for each node
nodes_throughput=(500mbit 500mbit 500mbit 500mbit 500mbit 500mbit 500mbit 500mbit)

declare -A clusters_pings
#pings between clusters and within a cluster
#(10 30 40)
#(30 15 50)
#(40 50 12)
clusters_pings[0,0]=10
clusters_pings[0,1]=30
clusters_pings[0,2]=40

clusters_pings[1,0]=30
clusters_pings[1,1]=15
clusters_pings[1,2]=50

clusters_pings[2,0]=40
clusters_pings[2,1]=50
clusters_pings[2,2]=12

declare -a containers=($(docker ps -f "ancestor=libra_validator_dynamic" -q))

if [ $nodes -ne ${#containers[@]} ]
then
    echo "ERROR: $nodes node(s) are specified, but ${#containers[@]} node(s) are running"
    echo "EXIT program"
    exit 1
fi

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