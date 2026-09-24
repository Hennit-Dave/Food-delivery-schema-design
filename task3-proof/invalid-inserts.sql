-- Each DO block catches the expected rejection, allowing psql to continue.
-- Unexpected success or a different constraint failure stops the run.
DO $$ BEGIN
 BEGIN
  INSERT INTO order_item(order_id,menu_item_id,quantity,unit_price_minor,currency)
  SELECT o.id,m.id,0,1200,'USD' FROM orders o JOIN menu_item m ON m.restaurant_id=o.restaurant_id WHERE o.status='placed' LIMIT 1;
  RAISE EXCEPTION 'TEST FAILED: zero quantity accepted';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM NOT LIKE '%quantity%' THEN RAISE; END IF;
  RAISE NOTICE 'PASS invalid insert 1: %',SQLERRM;
 END;
END $$;
DO $$ BEGIN
 BEGIN
  INSERT INTO review(order_id,rating) SELECT id,5 FROM orders WHERE status='placed' LIMIT 1;
  RAISE EXCEPTION 'TEST FAILED: review of undelivered order accepted';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM <> 'review_requires_delivered_order' THEN RAISE; END IF;
  RAISE NOTICE 'PASS invalid insert 2: %',SQLERRM;
 END;
END $$;
DO $$ BEGIN
 BEGIN
  INSERT INTO delivery(order_id,courier_id)
  SELECT o.id,c.id FROM orders o CROSS JOIN courier c WHERE o.status='accepted' AND c.name='Courier 1' AND NOT EXISTS(SELECT 1 FROM delivery d WHERE d.order_id=o.id) LIMIT 1;
  RAISE EXCEPTION 'TEST FAILED: busy courier assigned again';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM <> 'one_active_delivery_per_courier' THEN RAISE; END IF;
  RAISE NOTICE 'PASS invalid insert 3: %',SQLERRM;
 END;
END $$;
