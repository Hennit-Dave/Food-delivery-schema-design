-- Five representative queries map to the five requirements actions.
-- Mutating actions include their eligibility/read query; this is schema proof, not handlers.
-- 1. Place order: retrieve available menu prices for a selected restaurant.
SELECT id,name,price_minor,currency FROM menu_item
WHERE restaurant_id=(SELECT id FROM restaurant WHERE name='Kitchen 5')
AND deleted_at IS NULL AND is_available ORDER BY name,id LIMIT 20;
-- 2. Restaurant processes orders: list its incoming placed orders.
SELECT id,status,total_minor,currency,created_at FROM orders
WHERE restaurant_id=(SELECT id FROM restaurant WHERE name='Kitchen 5') AND status='placed'
ORDER BY created_at DESC,id LIMIT 20;
-- 3. Courier accepts work: oldest eligible unassigned orders.
SELECT o.id,o.restaurant_id,o.status,o.created_at FROM orders o
WHERE o.status IN ('accepted','preparing','ready')
AND NOT EXISTS(SELECT 1 FROM delivery d WHERE d.order_id=o.id)
ORDER BY o.created_at,o.id LIMIT 20;
-- 4. Customer tracks a selected order; ownership is part of the query.
SELECT id,status,updated_at FROM orders WHERE id=(SELECT id FROM orders WHERE customer_id=(SELECT id FROM customer WHERE email='customer1@example.test') ORDER BY created_at DESC LIMIT 1)
AND customer_id=(SELECT id FROM customer WHERE email='customer1@example.test');
-- 5. Review submission: eligible completed order not already reviewed.
SELECT o.id FROM orders o WHERE o.customer_id=(SELECT id FROM customer WHERE email='customer1@example.test')
AND o.status='delivered' AND NOT EXISTS(SELECT 1 FROM review r WHERE r.order_id=o.id)
ORDER BY o.created_at DESC LIMIT 1;
