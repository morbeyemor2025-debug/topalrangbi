-- ============================================================
-- SAMA RANG — Schéma PostgreSQL complet
-- Supabase / PostgreSQL 15
-- Appliquer dans l'ordre via Supabase SQL Editor ou migrations
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- Recherche full-text clients

-- ============================================================
-- 1. TABLES
-- ============================================================

-- Salons (tenants)
CREATE TABLE IF NOT EXISTS salons (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug              TEXT UNIQUE NOT NULL,
  name              TEXT NOT NULL,
  phone             TEXT,
  address           TEXT,
  city              TEXT DEFAULT 'Dakar',
  country           TEXT DEFAULT 'SN',
  logo_url          TEXT,
  plan              TEXT NOT NULL DEFAULT 'free'
                    CHECK (plan IN ('free','starter','pro','enterprise')),
  plan_expires_at   TIMESTAMPTZ,
  monthly_client_count INTEGER DEFAULT 0,  -- compteur mensuel plan Free
  settings          JSONB NOT NULL DEFAULT '{
    "avg_service_duration": 20,
    "notify_on_join": true,
    "notify_on_call": true,
    "currency": "XOF"
  }',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Utilisateurs (employés + admins)
CREATE TABLE IF NOT EXISTS users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  salon_id    UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  email       TEXT NOT NULL,
  phone       TEXT,
  full_name   TEXT,
  role        TEXT NOT NULL DEFAULT 'employee'
              CHECK (role IN ('admin','employee')),
  avatar_url  TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  last_login  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Clients (CRM)
CREATE TABLE IF NOT EXISTS clients (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id    UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  phone       TEXT NOT NULL,
  full_name   TEXT,
  visit_count INTEGER NOT NULL DEFAULT 0,
  total_spent DECIMAL(12,2) NOT NULL DEFAULT 0,
  last_visit  TIMESTAMPTZ,
  segment     TEXT NOT NULL DEFAULT 'new'
              CHECK (segment IN ('new','active','vip','inactive')),
  tags        TEXT[] NOT NULL DEFAULT '{}',
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (salon_id, phone)
);

-- Entrées file d'attente
CREATE TABLE IF NOT EXISTS queue_entries (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id      UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  client_id     UUID REFERENCES clients(id) ON DELETE SET NULL,
  client_name   TEXT NOT NULL,
  client_phone  TEXT,
  position      INTEGER,
  status        TEXT NOT NULL DEFAULT 'waiting'
                CHECK (status IN ('waiting','called','serving','done','no_show')),
  service_type  TEXT NOT NULL DEFAULT 'coupe'
                CHECK (service_type IN ('coupe','barbe','coupe_barbe')),
  price         DECIMAL(8,2),
  barber_id     UUID REFERENCES users(id) ON DELETE SET NULL,
  joined_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  called_at     TIMESTAMPTZ,
  served_at     TIMESTAMPTZ,
  done_at       TIMESTAMPTZ,
  wait_minutes  INTEGER,  -- calculé à la clôture
  date          DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Abonnements
CREATE TABLE IF NOT EXISTS subscriptions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id              UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  plan                  TEXT NOT NULL CHECK (plan IN ('starter','pro','enterprise')),
  status                TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','past_due','cancelled','trialing')),
  amount                DECIMAL(12,2) NOT NULL,
  currency              TEXT NOT NULL DEFAULT 'XOF',
  payment_method        TEXT CHECK (payment_method IN ('wave','orange_money','card')),
  external_id           TEXT,            -- ID chez Wave / Orange Money
  current_period_start  TIMESTAMPTZ NOT NULL,
  current_period_end    TIMESTAMPTZ NOT NULL,
  cancelled_at          TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Log notifications
CREATE TABLE IF NOT EXISTS notifications_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id    UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  client_id   UUID REFERENCES clients(id) ON DELETE SET NULL,
  type        TEXT NOT NULL
              CHECK (type IN ('join','called','promo','reminder','custom')),
  channel     TEXT NOT NULL DEFAULT 'whatsapp'
              CHECK (channel IN ('whatsapp','sms','email')),
  phone       TEXT,
  message     TEXT,
  status      TEXT NOT NULL DEFAULT 'sent'
              CHECK (status IN ('pending','sent','delivered','failed')),
  error_msg   TEXT,
  sent_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Analytics agrégées (pré-calculées chaque nuit)
CREATE TABLE IF NOT EXISTS daily_analytics (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id        UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  date            DATE NOT NULL,
  total_clients   INTEGER NOT NULL DEFAULT 0,
  completed       INTEGER NOT NULL DEFAULT 0,
  no_shows        INTEGER NOT NULL DEFAULT 0,
  total_revenue   DECIMAL(12,2) NOT NULL DEFAULT 0,
  avg_wait_min    INTEGER,
  peak_hour       INTEGER,   -- heure du pic (0-23)
  coupe_count     INTEGER NOT NULL DEFAULT 0,
  barbe_count     INTEGER NOT NULL DEFAULT 0,
  coupe_barbe_count INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (salon_id, date)
);

-- ============================================================
-- 2. INDEX
-- ============================================================

-- File d'attente — requêtes les plus fréquentes
CREATE INDEX IF NOT EXISTS idx_queue_salon_date_status
  ON queue_entries (salon_id, date, status);

CREATE INDEX IF NOT EXISTS idx_queue_salon_date
  ON queue_entries (salon_id, date DESC);

CREATE INDEX IF NOT EXISTS idx_queue_client
  ON queue_entries (client_id) WHERE client_id IS NOT NULL;

-- CRM clients
CREATE INDEX IF NOT EXISTS idx_clients_salon
  ON clients (salon_id);

CREATE INDEX IF NOT EXISTS idx_clients_segment
  ON clients (salon_id, segment);

CREATE INDEX IF NOT EXISTS idx_clients_last_visit
  ON clients (salon_id, last_visit DESC);

-- Recherche full-text clients (nom + téléphone)
CREATE INDEX IF NOT EXISTS idx_clients_name_trgm
  ON clients USING gin (full_name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_clients_phone_trgm
  ON clients USING gin (phone gin_trgm_ops);

-- Abonnements
CREATE INDEX IF NOT EXISTS idx_subscriptions_salon
  ON subscriptions (salon_id, status);

-- Analytics
CREATE INDEX IF NOT EXISTS idx_analytics_salon_date
  ON daily_analytics (salon_id, date DESC);

-- Notifications
CREATE INDEX IF NOT EXISTS idx_notif_salon_sent
  ON notifications_log (salon_id, sent_at DESC);

-- ============================================================
-- 3. ROW LEVEL SECURITY (RLS)
-- ============================================================

ALTER TABLE salons           ENABLE ROW LEVEL SECURITY;
ALTER TABLE users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE queue_entries    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_analytics  ENABLE ROW LEVEL SECURITY;

-- Helper : extraire salon_id du JWT
CREATE OR REPLACE FUNCTION auth_salon_id() RETURNS UUID AS $$
  SELECT (auth.jwt() ->> 'salon_id')::UUID;
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Helper : extraire role du JWT
CREATE OR REPLACE FUNCTION auth_role() RETURNS TEXT AS $$
  SELECT auth.jwt() ->> 'user_role';
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- ── salons ──────────────────────────────────────────────────
CREATE POLICY "salon_select_own" ON salons
  FOR SELECT USING (id = auth_salon_id());

CREATE POLICY "salon_update_admin" ON salons
  FOR UPDATE USING (id = auth_salon_id() AND auth_role() = 'admin');

-- ── users ───────────────────────────────────────────────────
CREATE POLICY "users_select_same_salon" ON users
  FOR SELECT USING (salon_id = auth_salon_id());

CREATE POLICY "users_update_own" ON users
  FOR UPDATE USING (id = auth.uid());

CREATE POLICY "users_insert_admin" ON users
  FOR INSERT WITH CHECK (salon_id = auth_salon_id() AND auth_role() = 'admin');

CREATE POLICY "users_delete_admin" ON users
  FOR DELETE USING (salon_id = auth_salon_id() AND auth_role() = 'admin');

-- ── clients ─────────────────────────────────────────────────
CREATE POLICY "clients_select_own_salon" ON clients
  FOR SELECT USING (salon_id = auth_salon_id());

CREATE POLICY "clients_insert_own_salon" ON clients
  FOR INSERT WITH CHECK (salon_id = auth_salon_id());

CREATE POLICY "clients_update_own_salon" ON clients
  FOR UPDATE USING (salon_id = auth_salon_id());

CREATE POLICY "clients_delete_admin" ON clients
  FOR DELETE USING (salon_id = auth_salon_id() AND auth_role() = 'admin');

-- ── queue_entries ───────────────────────────────────────────
-- Les employés voient + modifient leur file
CREATE POLICY "queue_select_own_salon" ON queue_entries
  FOR SELECT USING (salon_id = auth_salon_id());

-- Insert public (clients QR sans auth)
CREATE POLICY "queue_insert_public" ON queue_entries
  FOR INSERT WITH CHECK (
    -- Soit un employé connecté, soit une insertion publique validée côté API
    salon_id = auth_salon_id()
    OR auth.role() = 'anon'  -- L'API route valide les limites plan côté serveur
  );

CREATE POLICY "queue_update_employee" ON queue_entries
  FOR UPDATE USING (salon_id = auth_salon_id());

CREATE POLICY "queue_delete_employee" ON queue_entries
  FOR DELETE USING (salon_id = auth_salon_id());

-- ── subscriptions ────────────────────────────────────────────
CREATE POLICY "subscriptions_select_admin" ON subscriptions
  FOR SELECT USING (salon_id = auth_salon_id() AND auth_role() = 'admin');

CREATE POLICY "subscriptions_insert_admin" ON subscriptions
  FOR INSERT WITH CHECK (salon_id = auth_salon_id() AND auth_role() = 'admin');

-- ── notifications_log ────────────────────────────────────────
CREATE POLICY "notif_select_admin" ON notifications_log
  FOR SELECT USING (salon_id = auth_salon_id() AND auth_role() = 'admin');

CREATE POLICY "notif_insert_own_salon" ON notifications_log
  FOR INSERT WITH CHECK (salon_id = auth_salon_id());

-- ── daily_analytics ─────────────────────────────────────────
CREATE POLICY "analytics_select_admin" ON daily_analytics
  FOR SELECT USING (salon_id = auth_salon_id() AND auth_role() = 'admin');

-- ============================================================
-- 4. TRIGGERS & FONCTIONS MÉTIER
-- ============================================================

-- Trigger updated_at générique
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at_salons
  BEFORE UPDATE ON salons
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_updated_at_clients
  BEFORE UPDATE ON clients
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ── Auto-segmentation clients ────────────────────────────────
-- Se déclenche après chaque mise à jour des stats client
CREATE OR REPLACE FUNCTION fn_update_client_segment()
RETURNS TRIGGER AS $$
BEGIN
  NEW.segment := CASE
    WHEN NEW.visit_count >= 10 AND NEW.last_visit > NOW() - INTERVAL '30 days'
      THEN 'vip'
    WHEN NEW.last_visit < NOW() - INTERVAL '45 days'
      THEN 'inactive'
    WHEN NEW.visit_count >= 3
      THEN 'active'
    ELSE 'new'
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auto_segment_client
  BEFORE INSERT OR UPDATE OF visit_count, last_visit ON clients
  FOR EACH ROW EXECUTE FUNCTION fn_update_client_segment();

-- ── Auto-calcul wait_minutes à la clôture ───────────────────
CREATE OR REPLACE FUNCTION fn_calc_wait_minutes()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'done' AND OLD.status != 'done' THEN
    NEW.done_at    := NOW();
    NEW.wait_minutes := EXTRACT(EPOCH FROM (NOW() - OLD.joined_at))::INTEGER / 60;
  END IF;
  IF NEW.status = 'called' AND OLD.status = 'waiting' THEN
    NEW.called_at := NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER calc_wait_minutes
  BEFORE UPDATE OF status ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION fn_calc_wait_minutes();

-- ── Mise à jour CRM client après service terminé ─────────────
CREATE OR REPLACE FUNCTION fn_update_client_after_done()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'done' AND OLD.status != 'done' AND NEW.client_id IS NOT NULL THEN
    UPDATE clients
    SET
      visit_count  = visit_count + 1,
      total_spent  = total_spent + COALESCE(NEW.price, 0),
      last_visit   = NOW()
    WHERE id = NEW.client_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_client_crm
  AFTER UPDATE OF status ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION fn_update_client_after_done();

-- ── Recompact positions après suppression ────────────────────
CREATE OR REPLACE FUNCTION fn_reorder_queue()
RETURNS TRIGGER AS $$
BEGIN
  -- Renumérote les waiting du même jour après une suppression
  WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY joined_at ASC) AS new_pos
    FROM queue_entries
    WHERE salon_id = OLD.salon_id
      AND date = OLD.date
      AND status = 'waiting'
  )
  UPDATE queue_entries qe
  SET position = r.new_pos
  FROM ranked r
  WHERE qe.id = r.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reorder_queue_after_delete
  AFTER DELETE ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION fn_reorder_queue();

-- ── Compteur mensuel plan Free ───────────────────────────────
CREATE OR REPLACE FUNCTION fn_increment_monthly_counter()
RETURNS TRIGGER AS $$
BEGIN
  -- Reset le compteur au 1er du mois
  UPDATE salons
  SET monthly_client_count = CASE
    WHEN DATE_TRUNC('month', NOW()) > DATE_TRUNC('month', updated_at)
      THEN 1
    ELSE monthly_client_count + 1
  END
  WHERE id = NEW.salon_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER increment_monthly_counter
  AFTER INSERT ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION fn_increment_monthly_counter();

-- ============================================================
-- 5. FONCTIONS RPC (appelables depuis le client Supabase)
-- ============================================================

-- Stats du jour pour le dashboard
CREATE OR REPLACE FUNCTION get_today_stats(p_salon_id UUID)
RETURNS JSON AS $$
DECLARE
  today DATE := CURRENT_DATE;
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_clients',   COUNT(*),
    'completed',       COUNT(*) FILTER (WHERE status = 'done'),
    'no_shows',        COUNT(*) FILTER (WHERE status = 'no_show'),
    'waiting',         COUNT(*) FILTER (WHERE status = 'waiting'),
    'total_revenue',   COALESCE(SUM(price) FILTER (WHERE status = 'done'), 0),
    'avg_wait_min',    ROUND(AVG(wait_minutes) FILTER (WHERE wait_minutes IS NOT NULL)),
    'peak_hour',       MODE() WITHIN GROUP (ORDER BY EXTRACT(HOUR FROM joined_at))
  )
  INTO result
  FROM queue_entries
  WHERE salon_id = p_salon_id AND date = today;

  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revenus sur une période
CREATE OR REPLACE FUNCTION get_revenue_range(
  p_salon_id UUID,
  p_from DATE,
  p_to DATE
)
RETURNS TABLE (
  date DATE,
  revenue DECIMAL,
  clients INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    qe.date,
    COALESCE(SUM(qe.price), 0)::DECIMAL AS revenue,
    COUNT(*)::INTEGER AS clients
  FROM queue_entries qe
  WHERE qe.salon_id = p_salon_id
    AND qe.date BETWEEN p_from AND p_to
    AND qe.status = 'done'
  GROUP BY qe.date
  ORDER BY qe.date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Heatmap horaire (12 dernières semaines)
CREATE OR REPLACE FUNCTION get_hourly_heatmap(p_salon_id UUID)
RETURNS TABLE (hour INTEGER, avg_count NUMERIC) AS $$
BEGIN
  RETURN QUERY
  SELECT
    EXTRACT(HOUR FROM joined_at)::INTEGER AS hour,
    ROUND(COUNT(*)::NUMERIC / 84, 1)  AS avg_count  -- 12 semaines = 84 jours
  FROM queue_entries
  WHERE salon_id = p_salon_id
    AND joined_at > NOW() - INTERVAL '12 weeks'
  GROUP BY 1
  ORDER BY 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Clients inactifs à notifier (cron job)
CREATE OR REPLACE FUNCTION get_inactive_clients_to_notify(p_salon_id UUID)
RETURNS TABLE (
  client_id UUID,
  full_name TEXT,
  phone TEXT,
  days_since INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.full_name,
    c.phone,
    EXTRACT(DAY FROM NOW() - c.last_visit)::INTEGER AS days_since
  FROM clients c
  WHERE c.salon_id = p_salon_id
    AND c.phone IS NOT NULL
    AND c.segment = 'inactive'
    AND c.last_visit < NOW() - INTERVAL '30 days'
    -- Pas déjà notifié dans les 7 derniers jours
    AND NOT EXISTS (
      SELECT 1 FROM notifications_log nl
      WHERE nl.client_id = c.id
        AND nl.type = 'reminder'
        AND nl.sent_at > NOW() - INTERVAL '7 days'
    )
  ORDER BY c.last_visit ASC
  LIMIT 50;  -- max 50 par passage
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Agrégation journalière (appelée par cron chaque nuit à 23h55)
CREATE OR REPLACE FUNCTION aggregate_daily_stats(p_date DATE DEFAULT CURRENT_DATE - 1)
RETURNS void AS $$
BEGIN
  INSERT INTO daily_analytics (
    salon_id, date, total_clients, completed, no_shows,
    total_revenue, avg_wait_min, peak_hour,
    coupe_count, barbe_count, coupe_barbe_count
  )
  SELECT
    salon_id,
    p_date,
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'done'),
    COUNT(*) FILTER (WHERE status = 'no_show'),
    COALESCE(SUM(price) FILTER (WHERE status = 'done'), 0),
    ROUND(AVG(wait_minutes) FILTER (WHERE wait_minutes IS NOT NULL))::INTEGER,
    (MODE() WITHIN GROUP (ORDER BY EXTRACT(HOUR FROM joined_at)))::INTEGER,
    COUNT(*) FILTER (WHERE service_type = 'coupe'),
    COUNT(*) FILTER (WHERE service_type = 'barbe'),
    COUNT(*) FILTER (WHERE service_type = 'coupe_barbe')
  FROM queue_entries
  WHERE date = p_date
  GROUP BY salon_id
  ON CONFLICT (salon_id, date)
  DO UPDATE SET
    total_clients     = EXCLUDED.total_clients,
    completed         = EXCLUDED.completed,
    no_shows          = EXCLUDED.no_shows,
    total_revenue     = EXCLUDED.total_revenue,
    avg_wait_min      = EXCLUDED.avg_wait_min,
    peak_hour         = EXCLUDED.peak_hour,
    coupe_count       = EXCLUDED.coupe_count,
    barbe_count       = EXCLUDED.barbe_count,
    coupe_barbe_count = EXCLUDED.coupe_barbe_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 6. JWT HOOK — Injecter salon_id + role dans le token
-- ============================================================
-- À configurer dans : Supabase Dashboard > Authentication > Hooks

CREATE OR REPLACE FUNCTION custom_access_token_hook(event JSONB)
RETURNS JSONB AS $$
DECLARE
  claims     JSONB;
  user_rec   RECORD;
BEGIN
  claims := event -> 'claims';

  SELECT u.salon_id, u.role, s.plan, s.slug
  INTO user_rec
  FROM users u
  JOIN salons s ON s.id = u.salon_id
  WHERE u.id = (event ->> 'user_id')::UUID;

  IF FOUND THEN
    claims := jsonb_set(claims, '{salon_id}',   to_jsonb(user_rec.salon_id::TEXT));
    claims := jsonb_set(claims, '{user_role}',  to_jsonb(user_rec.role));
    claims := jsonb_set(claims, '{salon_plan}', to_jsonb(user_rec.plan));
    claims := jsonb_set(claims, '{salon_slug}', to_jsonb(user_rec.slug));
  END IF;

  RETURN jsonb_set(event, '{claims}', claims);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION custom_access_token_hook FROM PUBLIC;

-- ============================================================
-- 7. REALTIME — Activer sur les tables critiques
-- ============================================================

-- Dans Supabase Dashboard > Database > Replication, activer pour :
-- ✅ queue_entries  (temps réel pour le dashboard employé)
-- ✅ clients        (sync CRM)
-- Les autres tables n'ont pas besoin de realtime

ALTER PUBLICATION supabase_realtime ADD TABLE queue_entries;
ALTER PUBLICATION supabase_realtime ADD TABLE clients;

-- ============================================================
-- 8. SEED DATA (développement uniquement)
-- ============================================================

DO $$
BEGIN
  IF current_database() LIKE '%local%' OR current_database() LIKE '%dev%' THEN

    -- Salon de démo
    INSERT INTO salons (id, slug, name, phone, address, city, plan)
    VALUES (
      '00000000-0000-0000-0000-000000000001',
      'salon-teranga',
      'Salon Teranga',
      '+221771234567',
      'Rue 10, Médina',
      'Dakar',
      'starter'
    ) ON CONFLICT (slug) DO NOTHING;

    -- Clients de démo
    INSERT INTO clients (salon_id, phone, full_name, visit_count, total_spent, last_visit)
    VALUES
      ('00000000-0000-0000-0000-000000000001', '221771234567', 'Mamadou Diallo', 14, 28500, NOW() - INTERVAL '7 days'),
      ('00000000-0000-0000-0000-000000000001', '221783456789', 'Oumar Ba', 6, 9000, NOW() - INTERVAL '3 days'),
      ('00000000-0000-0000-0000-000000000001', '221761122334', 'Pape Gueye', 1, 2500, NOW() - INTERVAL '45 days'),
      ('00000000-0000-0000-0000-000000000001', '221776655443', 'Serigne Mbaye', 22, 44000, NOW() - INTERVAL '1 day')
    ON CONFLICT (salon_id, phone) DO NOTHING;

  END IF;
END $$;
