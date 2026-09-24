-- The two broadest action queries: incoming-order queue and cross-restaurant courier discovery.
-- No enable_seqscan override: plans reflect the normal cost-based planner.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id,status,total_minor,currency,created_at FROM orders
WHERE restaurant_id=(SELECT id FROM restaurant WHERE name='Kitchen 5') AND status='placed'
ORDER BY created_at DESC,id LIMIT 20;
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id,o.restaurant_id,o.status,o.created_at FROM orders o
WHERE o.status IN ('accepted','preparing','ready')
AND NOT EXISTS(SELECT 1 FROM delivery d WHERE d.order_id=o.id)
ORDER BY o.created_at,o.id LIMIT 20;
