./harness.py exec "test -f /var/lib/snail-core/.setup-complete && echo 'READY' || echo 'STILL SETTING UP'" --ignore-errors
./harness.py configure --api-endpoint "http://192.168.124.1:8080/api/v1/ingest"

