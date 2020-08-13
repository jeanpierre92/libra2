#!/bin/bash
container_log_location="/jp_metrics"
host_directory="/home/jeanpierre/LibraMetrics/containersMetricsFiles"
files_to_merge=("jp_ac_client_transaction.csv"
                "jp_consensus_process_new_round.csv"
                "jp_consensus_process_proposal.csv"
                "jp_mempool_process_incoming_transactions.csv"
                "jp_consensus_process_block_retrieval.csv"
                "jp_consensus_process_local_timeout.csv")

declare -a containers=($(cat containers_id.txt))
echo "Copying from ${#containers[@]} containers..."

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
#merges files from n-containers row by row
#thereby removing any empty lines
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