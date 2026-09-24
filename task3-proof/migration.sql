BEGIN;
CREATE TABLE customer (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, email text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE TABLE restaurant (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, pickup_address jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE TABLE courier (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, phone text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE TABLE menu_item (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL REFERENCES restaurant, name text NOT NULL, description text, price_minor bigint NOT NULL CHECK(price_minor > 0), currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'), is_available boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE TABLE orders (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), customer_id uuid NOT NULL REFERENCES customer, restaurant_id uuid NOT NULL REFERENCES restaurant, status text NOT NULL DEFAULT 'placed' CHECK(status IN ('placed','accepted','preparing','ready','picked_up','delivered','cancelled')), delivery_address_snapshot jsonb NOT NULL, total_minor bigint NOT NULL CHECK(total_minor > 0), currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE order_item (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL REFERENCES orders, menu_item_id uuid NOT NULL REFERENCES menu_item, quantity integer NOT NULL CHECK(quantity > 0), unit_price_minor bigint NOT NULL CHECK(unit_price_minor > 0), currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(order_id,menu_item_id));
CREATE TABLE delivery (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL UNIQUE REFERENCES orders, courier_id uuid NOT NULL REFERENCES courier, assigned_at timestamptz NOT NULL DEFAULT now(), picked_up_at timestamptz, delivered_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), CHECK(delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at)), CHECK(picked_up_at IS NULL OR picked_up_at >= assigned_at));
CREATE TABLE review (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL UNIQUE REFERENCES orders, rating integer NOT NULL CHECK(rating BETWEEN 1 AND 5), comment text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz);
CREATE INDEX restaurant_orders ON orders(restaurant_id,status,created_at DESC,id);
CREATE INDEX assignable_orders ON orders(created_at,id) WHERE status IN ('accepted','preparing','ready');
CREATE INDEX customer_orders ON orders(customer_id,created_at DESC,id);
CREATE INDEX courier_deliveries ON delivery(courier_id);
-- order_item UNIQUE(order_id, menu_item_id) already serves lookups by order_id.
CREATE INDEX restaurant_menu ON menu_item(restaurant_id,name,id) WHERE deleted_at IS NULL;

CREATE FUNCTION stamp_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := clock_timestamp(); RETURN NEW; END $$;
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['customer','restaurant','courier','menu_item','orders','order_item','delivery','review'] LOOP EXECUTE format('CREATE TRIGGER stamp_update BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION stamp_update()',t); END LOOP; END $$;

CREATE FUNCTION fixed_references() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE col text; BEGIN
 FOREACH col IN ARRAY TG_ARGV LOOP
  IF to_jsonb(NEW)->col IS DISTINCT FROM to_jsonb(OLD)->col THEN RAISE EXCEPTION 'immutable field: %.%', TG_TABLE_NAME,col USING ERRCODE='23514'; END IF;
 END LOOP; RETURN NEW;
END $$;
CREATE TRIGGER fixed_refs BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION fixed_references('customer_id','restaurant_id','currency','delivery_address_snapshot','total_minor');
CREATE TRIGGER fixed_refs BEFORE UPDATE ON menu_item FOR EACH ROW EXECUTE FUNCTION fixed_references('restaurant_id');
CREATE TRIGGER fixed_refs BEFORE UPDATE ON order_item FOR EACH ROW EXECUTE FUNCTION fixed_references('order_id','menu_item_id','quantity','unit_price_minor','currency');
CREATE TRIGGER fixed_refs BEFORE UPDATE ON delivery FOR EACH ROW EXECUTE FUNCTION fixed_references('order_id','courier_id');
CREATE TRIGGER fixed_refs BEFORE UPDATE ON review FOR EACH ROW EXECUTE FUNCTION fixed_references('order_id');

CREATE FUNCTION validate_order_items() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE oid uuid; n bigint; amount numeric; BEGIN
 IF TG_TABLE_NAME='orders' THEN oid := NEW.id;
 ELSIF TG_OP='DELETE' THEN oid := OLD.order_id;
 ELSE oid := NEW.order_id; END IF;
 PERFORM 1 FROM orders WHERE id=oid FOR UPDATE;
 SELECT count(*),sum(quantity::numeric*unit_price_minor) INTO n,amount FROM order_item WHERE order_id=oid;
 IF n=0 THEN RAISE EXCEPTION 'order_requires_items' USING ERRCODE='23514',CONSTRAINT='order_requires_items'; END IF;
 IF amount <> (SELECT total_minor FROM orders WHERE id=oid) THEN RAISE EXCEPTION 'order_total_matches_items' USING ERRCODE='23514',CONSTRAINT='order_total_matches_items'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER order_integrity AFTER INSERT OR UPDATE ON orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_order_items();
CREATE CONSTRAINT TRIGGER item_integrity AFTER INSERT OR UPDATE OR DELETE ON order_item DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_order_items();

CREATE FUNCTION validate_item() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o orders; m menu_item; BEGIN
 SELECT * INTO STRICT o FROM orders WHERE id=NEW.order_id FOR UPDATE;
 SELECT * INTO STRICT m FROM menu_item WHERE id=NEW.menu_item_id FOR SHARE;
 IF o.status <> 'placed' THEN RAISE EXCEPTION 'items require placed order' USING ERRCODE='23514'; END IF;
 IF m.restaurant_id <> o.restaurant_id THEN RAISE EXCEPTION 'order_item_restaurant_matches' USING ERRCODE='23514'; END IF;
 IF NEW.currency <> o.currency OR NEW.currency <> m.currency THEN RAISE EXCEPTION 'order_currency_matches' USING ERRCODE='23514'; END IF;
 IF NOT m.is_available OR m.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'menu item unavailable' USING ERRCODE='23514'; END IF;
 IF NEW.unit_price_minor <> m.price_minor THEN RAISE EXCEPTION 'price must match menu at placement' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validate_item BEFORE INSERT ON order_item FOR EACH ROW EXECUTE FUNCTION validate_item();

CREATE FUNCTION validate_order_state() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 IF TG_OP='INSERT' THEN
  IF NEW.status <> 'placed' THEN RAISE EXCEPTION 'orders start placed' USING ERRCODE='23514'; END IF;
 ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
  IF NOT ((OLD.status='placed' AND NEW.status IN ('accepted','cancelled')) OR (OLD.status='accepted' AND NEW.status='preparing') OR (OLD.status='preparing' AND NEW.status='ready') OR (OLD.status='ready' AND NEW.status='picked_up') OR (OLD.status='picked_up' AND NEW.status='delivered')) THEN RAISE EXCEPTION 'invalid_order_transition: % -> %',OLD.status,NEW.status USING ERRCODE='23514'; END IF;
  IF NEW.status IN ('picked_up','delivered') THEN
   IF NOT EXISTS (SELECT 1 FROM delivery WHERE order_id=NEW.id) THEN RAISE EXCEPTION 'delivery assignment required' USING ERRCODE='23514'; END IF;
   IF NEW.status='picked_up' THEN UPDATE delivery SET picked_up_at=clock_timestamp() WHERE order_id=NEW.id;
   ELSE UPDATE delivery SET delivered_at=clock_timestamp() WHERE order_id=NEW.id; END IF;
  END IF;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER validate_state BEFORE INSERT OR UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION validate_order_state();

CREATE FUNCTION assign_courier() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s text; BEGIN
 -- Intended isolation: READ COMMITTED. Every assignment locks the same parent first.
 PERFORM 1 FROM courier WHERE id=NEW.courier_id AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'courier unavailable' USING ERRCODE='23514'; END IF;
 SELECT status INTO s FROM orders WHERE id=NEW.order_id FOR UPDATE;
 IF s IS NULL OR s NOT IN ('accepted','preparing','ready') THEN RAISE EXCEPTION 'order not assignable' USING ERRCODE='23514'; END IF;
 IF EXISTS (SELECT 1 FROM delivery d JOIN orders o ON o.id=d.order_id WHERE d.courier_id=NEW.courier_id AND o.status NOT IN ('delivered','cancelled')) THEN RAISE EXCEPTION 'one_active_delivery_per_courier' USING ERRCODE='23514',CONSTRAINT='one_active_delivery_per_courier'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER assign_courier BEFORE INSERT ON delivery FOR EACH ROW EXECUTE FUNCTION assign_courier();
CREATE FUNCTION validate_review() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM orders WHERE id=NEW.order_id AND status='delivered') THEN RAISE EXCEPTION 'review_requires_delivered_order' USING ERRCODE='23514',CONSTRAINT='review_requires_delivered_order'; END IF;
 RETURN NEW; END $$;
CREATE TRIGGER validate_review BEFORE INSERT ON review FOR EACH ROW EXECUTE FUNCTION validate_review();
CREATE FUNCTION retain_transaction() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'transaction records cannot be deleted through ordinary operations' USING ERRCODE='23514'; END $$;
CREATE TRIGGER retain_record BEFORE DELETE ON orders FOR EACH ROW EXECUTE FUNCTION retain_transaction();
CREATE TRIGGER retain_record BEFORE DELETE ON order_item FOR EACH ROW EXECUTE FUNCTION retain_transaction();
CREATE TRIGGER retain_record BEFORE DELETE ON delivery FOR EACH ROW EXECUTE FUNCTION retain_transaction();
COMMIT;
