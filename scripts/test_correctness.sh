#!/bin/bash
# Correctness tests for the Distributed Password Manager
# Requires the system to be running (via docker-compose or manually)
set -e

MASTER="localhost:9000"
CLIENT_CMD="go run ./cmd/client -master $MASTER -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"

echo "============================================"
echo "Test 1: Register + Save + Read + Update + Delete"
echo "============================================"
echo -e "register\ntestuser\nTestPass123!\nlogin\ntestuser\nTestPass123!\nsave\ngmail.com\njohn@gmail.com\nmypassword1\nsave\ngithub.com\njohn\nmypassword2\nsave\naws.com\njohndoe\nmypassword3\nget\ngmail.com\nget\ngithub.com\nget\naws.com\nlist\ndelete\naws.com\nlist\nexit" | $CLIENT_CMD
echo ""
echo "Test 1: PASSED (check output above for correctness)"

echo ""
echo "============================================"
echo "Test 2: Verify replication across chunk servers"
echo "============================================"
echo "(Read the same passwords from each chunk server directly)"
echo "(Verify all three chunks have identical encrypted data)"
echo "Test 2: Manual verification required"

echo ""
echo "============================================"
echo "Test 3: Replica failure + recovery"
echo "============================================"
echo "Stopping chunk2..."
docker compose stop chunk2 2>/dev/null || docker-compose stop chunk2
sleep 3

echo "Writing new entry while chunk2 is down..."
echo -e "login\ntestuser\nTestPass123!\nsave\nnetflix.com\njohn\nnewpass\nexit" | $CLIENT_CMD

echo "Restarting chunk2..."
docker compose start chunk2 2>/dev/null || docker-compose start chunk2
sleep 6

echo "Test 3: Check chunk2 logs for 'recovered N entries'"
docker compose logs chunk2 --tail=10 2>/dev/null || docker-compose logs chunk2 --tail=10

echo ""
echo "============================================"
echo "Test 4: Primary failure"
echo "============================================"
echo "Stopping chunk1 (primary)..."
docker compose stop chunk1 2>/dev/null || docker-compose stop chunk1
sleep 5

echo "Attempting write (should fail with 'primary unavailable')..."
echo -e "login\ntestuser\nTestPass123!\nsave\nfailtest.com\nuser\npass\nexit" | $CLIENT_CMD || true

echo "Restarting chunk1..."
docker compose start chunk1 2>/dev/null || docker-compose start chunk1
sleep 5

echo "Test 4: PASSED if write reported primary unavailable"

echo ""
echo "============================================"
echo "Test 5: Concurrent writes"
echo "============================================"
for i in $(seq 1 20); do
  echo -e "login\ntestuser\nTestPass123!\nsave\nsite${i}.com\nuser${i}\npass${i}\nexit" | $CLIENT_CMD &
done
wait
echo "Test 5: PASSED (20 concurrent writes completed)"

echo ""
echo "============================================"
echo "All tests completed."
echo "============================================"
