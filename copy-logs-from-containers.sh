#!/bin/bash
declare -a containers=($(cat containers_id.txt))
echo "Copying from ${#containers[@]} containers..."

for (( i=0; i<${#containers[@]}; i++ ))
do
    echo "Copied from ${containers[i]}"
    docker cp ${containers[i]}:/jp_metrics /home/jeanpierre/LibraMetrics/containersMetricsFiles/container$i
done