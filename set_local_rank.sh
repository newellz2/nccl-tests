#!/bin/bash
# Ensure LOCAL_RANK is set, default to 0 if OMPI variable isn't present (adjust if needed)
export LOCAL_RANK=${OMPI_COMM_WORLD_LOCAL_RANK:-0}

CORE=""

case $LOCAL_RANK in
    0)
        CORE="48,49"
    ;;
    1)
        CORE="50,51"
    ;;
    2)
        CORE="52,53"
    ;;
    3)
        CORE="54,55"
    ;;
    4)
        CORE="0,1"
    ;;
    5)
        CORE="2,3"
    ;;
    6)
        CORE="4,5"
    ;;
    7)
        CORE="6,7"
    ;;
    *)
        echo "Error: LOCAL_RANK ($LOCAL_RANK) is not between 0 and 7." >&2
        exit 1
    ;;
esac

# Export the variables determined by the case statement
export CORE
export CUDA_VISIBLE_DEVICES

hostname=$(hostname)
echo "Hostname: ${hostname}, Local Rank: ${LOCAL_RANK}, Core: ${CORE}, CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES}"

if [ -z "${CORE}" ]; then
  echo "Error: CORE variable was not set. Exiting." >&2
  exit 1
fi

echo "Running command with taskset -c '${CORE}' nice -n -20 '$@'"
taskset -c "${CORE}" nice -n -20 "$@"
