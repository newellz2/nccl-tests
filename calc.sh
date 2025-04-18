#!/bin/bash


pids=$(grep -Po '(?<=pid: )\d+' out | sort | uniq)


for p in ${pids[@]}; do
  echo "PIDs: ${p}"
  stats=$(grep "pid: ${p}" out | awk '{ print $9 }'| grep -Po '\d+' | datamash -R 2 mean 1 min 1 max 1 sstdev 1)
  echo ${stats}
  printf "\n"
done


