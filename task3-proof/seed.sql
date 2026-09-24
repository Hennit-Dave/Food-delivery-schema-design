-- Fresh database only. Re-run the proof runner to recreate an isolated database.
BEGIN;
DO $$
DECLARE rs uuid[] := '{}'; cs uuid[] := '{}'; ms uuid[] := '{}'; ds uuid[] := '{}'; rid uuid; cid uuid; mid uuid; did uuid; oid uuid; i integer; slot integer;
BEGIN
 FOR i IN 1..24 LOOP
  INSERT INTO restaurant(name,pickup_address) VALUES('Kitchen '||i,'{"line1":"12 Market Street","city":"Chicago","postcode":"60601"}') RETURNING id INTO rid; rs := array_append(rs,rid);
  INSERT INTO menu_item(restaurant_id,name,description,price_minor,currency) VALUES(rid,'Rice bowl','Vegetables and rice',1200,'USD') RETURNING id INTO mid; ms := array_append(ms,mid);
 END LOOP;
 FOR i IN 1..60 LOOP
  INSERT INTO customer(name,email) VALUES('Customer '||i,'customer'||i||'@example.test') RETURNING id INTO cid; cs := array_append(cs,cid);
 END LOOP;
 FOR i IN 1..6 LOOP
  INSERT INTO courier(name,phone) VALUES('Courier '||i,'+1555000'||lpad(i::text,4,'0')) RETURNING id INTO did; ds := array_append(ds,did);
 END LOOP;
 FOR i IN 1..1200 LOOP
  slot := ((i-1)%24)+1;
  INSERT INTO orders(customer_id,restaurant_id,delivery_address_snapshot,total_minor,currency,created_at)
   VALUES(cs[((i-1)%60)+1],rs[slot],'{"line1":"45 Lake Street","city":"Chicago","postcode":"60601"}',2400,'USD',now()-make_interval(mins=>1200-i)) RETURNING id INTO oid;
  INSERT INTO order_item(order_id,menu_item_id,quantity,unit_price_minor,currency) VALUES(oid,ms[slot],2,1200,'USD');
  IF i<=1140 THEN
   UPDATE orders SET status='accepted' WHERE id=oid;
   UPDATE orders SET status='preparing' WHERE id=oid;
   UPDATE orders SET status='ready' WHERE id=oid;
   INSERT INTO delivery(order_id,courier_id) VALUES(oid,ds[1]);
   UPDATE orders SET status='picked_up' WHERE id=oid;
   UPDATE orders SET status='delivered' WHERE id=oid;
   IF i%3=0 THEN INSERT INTO review(order_id,rating,comment) VALUES(oid,5,'Delivered warm.'); END IF;
  ELSIF i<=1170 THEN UPDATE orders SET status='accepted' WHERE id=oid;
  ELSIF i<=1180 THEN UPDATE orders SET status='cancelled' WHERE id=oid;
  END IF;
 END LOOP;
 SELECT id INTO oid FROM orders WHERE status='accepted' ORDER BY created_at LIMIT 1;
 INSERT INTO delivery(order_id,courier_id) VALUES(oid,ds[1]);
END $$;
COMMIT;
ANALYZE;
