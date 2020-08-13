#!/bin/bash
for (( i=1; i<3; i++ ))
do
    logs=$logs" test"$i".txt"
done
echo $logs
paste -d '\n' $logs > test3.txt
sed -i '/^$/d' test3.txt