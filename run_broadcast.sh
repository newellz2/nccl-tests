#!/bin/bash

module load nvhpc-hpcx-2.20-cuda12

make clean
make -j 8 MPI=1

for i in {0..7}; do 
	rm rank_data.csv; 
	mpirun \
	-x NCCL_ALGO=RING \
	-x NCCL_NVLS_ENABLE=0 \
	-x NCCL_TOPO_FILE=topo.xml \
	-x NCCL_MIN_NCHANNELS=32 \
	-x NCCL_PXN_DISABLE=1 \
	-x NCCL_P2P_DISABLE=0 \
	-x NCCL_DEBUG=INFO \
	-x NCCL_IGNORE_CPU_AFFINITY=1 \
	-x NCCL_DEBUG_SUBSYS=GRAPH \
	-x NCCL_P2P_NET_CHUNKSIZE=262144 \
	-np 8 --map-by ppr:8:node \
	--allow-run-as-root \
	build/broadcast_perf -t 1 -g 1 -b 8G -e 8G -n 1 -m 1 -i 0 -K rank_data.csv -r $i -L 100 | tee job_${i}.log
done
