provider nccl_tests_sdt
{
    probe bench_test_start(int iterations);
    probe bench_test_stop(int iterations);

    probe start_coll_start(int iter);
    probe start_coll_stop(int iter);

    probe barrier_start(int iterations);
    probe barrier_stop(int iterations);

    probe stream_sync_cuda_steam_query_start(int gpu);
    probe stream_sync_cuda_steam_query_stop(int gpu);
};
