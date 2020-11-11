#!/bin/bash

#Arg0 = logs destination location on host (eg: "/home/jeanpierre/LibraMetrics/containersMetricsFiles")
#Arg1 = 0:Keep the individual container files
#       1:Delete container logs and only keep the logs

if [ "$#" -ne 2 ]
then
    echo "ABORTING: this script expects 2 arguments!"
    echo "eg: /home/jeanpierre/LibraMetrics/containersMetricsFiles 1"
    echo "meaning, copy logs to that location and only keep the merged folder"
    exit 1
fi

container_log_location="/jp_metrics"
host_directory=$1
files_to_merge=("jp_ac_client_transaction.csv"
                "jp_consensus_process_new_round.csv"
                "jp_consensus_process_proposal.csv"
                "jp_consensus_ensure_round_and_sync_up.csv"
                "jp_mempool_process_incoming_transactions.csv")

declare -a containers=($(cat containers_id.txt))
if [ $? -eq 0 ]
then
    echo "Copying from ${#containers[@]} containers..."
else
    echo "ABORTING: Could not retrieve the containers_id's from containers_id.txt"
    echo "Make sure that containers_id.txt is present in the current folder"
    exit 1
fi

today=`date '+%Y_%m_%d__%H_%M_%S'`;
dir="$host_directory/$today"
mkdir -p $dir
for (( i=0; i<${#containers[@]}; i++ ))
do
    echo "Copied from ${containers[i]}"
    command="docker cp ${containers[i]}:$container_log_location $dir/container$i/"
    $command
done

mkdir -p $dir/"merged/"
#Merges files from n-containers row by row
#and removing any empty lines
function merge_log {
    declare -a logs
    for (( i=0; i<${#containers[@]}; i++ ))
    do
        logs=$logs" $dir/container$i/$1"
    done

    echo "Merging $1"
    paste -d '\n' $logs > $dir/"merged"/$1
    sed -i '/^$/d' $dir/"merged"/$1
}

#Attempt to merge the log files together
for (( j=0; j<${#files_to_merge[@]}; j++ ))
do
    merge_log "${files_to_merge[$j]}"
done

#Move logs that do not require merging
cp $dir/"container0/jp_blockstore_process_block.csv" $dir/"merged"
cp $dir/"container0/jp_cpu_load.csv" $dir/"merged"
cp $dir/"container0/jp_mempool_size.csv" $dir/"merged"

#Delete the container files if this is specified in the arguments
if [ $2 -eq 1 ]
then
    for (( i=0; i<${#containers[@]}; i++ ))
    do
        rm -rf $dir/"container$i"
    done
fi