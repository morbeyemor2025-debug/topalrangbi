-- ============================================================
-- SAMA RANG — Migration complète Supabase
-- Version : 1.0
-- Exécuter dans : Supabase Dashboard > SQL Editor
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- Recherche full-text clients

-- ============================================================
-- 1. SALONS
-- ============================================================
CREATE TABLE salons (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            TEXT UNIQUE NOT NULL,
  name            TEXT NOT NULL,
  phone           TEXT,
  address         TEXT,
  city            TEXT DEFAULT 'Dakar',
  country         TEXT DEFAULT 'SN',
  logo_url        TEXT,
  plan            TEXT NOT NULL DEFAULT 'free'
                    CHECK (plan IN ('free','starter','pro','enterprise')),
  plan_expires_at TIMESTAMPTZ,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  settings        JSONB NOT NULL DEFAULT '{
    "avg_service_minutes": 20,
    "max_queue_size": 50,
    "whatsapp_enabled": false,
    "notifications": {
      "on_join": true,
      "on_called": true,
      "reminder_days": 30
    }
  }',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_salons_slug ON salons(slug);
CREATE INDEX idx_salons_plan ON salons(plan);

-- ============================================================
-- 2. USERS (employés + admins)
-- ============================================================
CREATE TABLE users (
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

CREATE INDEX idx_users_salon  ON users(salon_id);
CREATE INDEX idx_users_role   ON users(salon_id, role);

-- ============================================================
-- 3. CLIENTS (CRM)
-- ============================================================
CREATE TABLE clients (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id    UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  phone       TEXT NOT NULL,
  full_name   TEXT,
  visit_count INTEGER NOT NULL DEFAULT 0,
  total_spent DECIMAL(10,2) NOT NULL DEFAULT 0,
  last_visit  TIMESTAMPTZ,
  segment     TEXT NOT NULL DEFAULT 'new'
                CHECK (segment IN ('new','active','vip','inactive')),
  tags        TEXT[] NOT NULL DEFAULT '{}',
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (salon_id, phone)
);

CREATE INDEX idx_clients_salon   ON clients(salon_id);
CREATE INDEX idx_clients_segment ON clients(salon_id, segment);
CREATE INDEX idx_clients_phone   ON clients(salon_id, phone);
-- Index full-text pour la recherche par nom
CREATE INDEX idx_clients_name_trgm ON clients USING gin(full_name gin_trgm_ops);

-- ============================================================
-- 4. QUEUE ENTRIES (file d'attente)
-- ============================================================
CREATE TABLE queue_entries (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id     UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  client_id    UUID REFERENCES clients(id) ON DELETE SET NULL,
  client_name  TEXT NOT NULL,
  client_phone TEXT,
  position     INTEGER,
  status       TEXT NOT NULL DEFAULT 'waiting'
                 CHECK (status IN ('waiting','called','serving','done','no_show')),
  service_type TEXT NOT NULL DEFAULT 'coupe'
                 CHECK (service_type IN ('coupe','barbe','coupe_barbe')),
  price        DECIMAL(8,2),
  barber_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  called_at    TIMESTAMPTZ,
  served_at    TIMESTAMPTZ,
  done_at      TIMESTAMPTZ,
  wait_minutes INTEGER,
  date         DATE NOT NULL DEFAULT CURRENT_DATE,
  notes        TEXT
);

CREATE INDEX idx_queue_salon_date    ON queue_entries(salon_id, date);
CREATE INDEX idx_queue_salon_status  ON queue_entries(salon_id, status);
CREATE INDEX idx_queue_client        ON queue_entries(client_id);
CREATE INDEX idx_queue_date_status   ON queue_entries(salon_id, date, status)
  WHERE status IN ('waiting','called','serving');

-- ============================================================
-- 5. SUBSCRIPTIONS
-- ============================================================
CREATE TABLE subscriptions (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id             UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  plan                 TEXT NOT NULL CHECK (plan IN ('starter','pro','enterprise')),
  status               TEXT NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','past_due','cancelled','trialing')),
  amount               DECIMAL(10,2) NOT NULL,
  currency             TEXT NOT NULL DEFAULT 'XOF',
  payment_method       TEXT CHECK (payment_method IN ('wave','orange_money','card','manual')),
  payment_ref          TEXT,           -- Référence Wave/OM
  current_period_start TIMESTAMPTZ NOT NULL,
  current_period_end   TIMESTAMPTZ NOT NULL,
  cancelled_at         TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_subs_salon  ON subscriptions(salon_id);
CREATE INDEX idx_subs_status ON subscriptions(status, current_period_end);

-- ============================================================
-- 6. NOTIFICATIONS LOG
-- ============================================================
CREATE TABLE notifications_log (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  salon_id   UUID NOT NULL REFERENCES salons(id) ON DELETE CASCADE,
  client_id  UUID REFERENCES clients(id) ON DELETE SET NULL,
  entry_id   UUID REFERENCES queue_entries(id) ON DELETE SET NULL,
  type       TEXT NOT NULL
               CHECK (type IN ('join','called','promo','reminder','custom')),
  channel    TEXT NOT NULL DEFAULT 'whatsapp'
               CHECK (channel IN ('whatsapp','sms','email')),
  phone      TEXT,
  message    TEXT,
  status     TEXT NOT NULL DEFAULT 'sent'
               CHECK (status IN ('sent','delivered','failed','pending')),
  wa_msg_id  TEXT,           -- ID message WhatsApp Business API
  error_msg  TEXT,
  sent_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notif_salon  ON notifications_log(salon_id, sent_at DESC);
CREATE INDEX idx_notif_client ON notifications_log(client_id);

-- ============================================================
-- 7. ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Activer RLS sur toutes les tables
ALTER TABLE salons           ENABLE ROW LEVEL SECURITY;
ALTER TABLE users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE queue_entries    ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications_log ENABLE ROW LEVEL SECURITY;

-- ── Fonction helper : récupérer salon_id du JWT ────────────
CREATE OR REPLACE FUNCTION auth.salon_id() RETURNS UUID AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'app_metadata' ->> 'salon_id')::UUID,
    (auth.jwt() -> 'user_metadata' ->> 'salon_id')::UUID
  );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth.user_role() RETURNS TEXT AS $$
  SELECT COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'role',
    'employee'
  );
$$ LANGUAGE sql STABLE;

-- ── SALONS policies ────────────────────────────────────────
CREATE POLICY "Salon visible par ses membres"
  ON salons FOR SELECT
  USING (id = auth.salon_id());

CREATE POLICY "Salon modifiable par admin"
  ON salons FOR UPDATE
  USING (id = auth.salon_id() AND auth.user_role() = 'admin');

-- ── USERS policies ────────────────────────────────────────
CREATE POLICY "Users visibles dans le même salon"
  ON users FOR SELECT
  USING (salon_id = auth.salon_id());

CREATE POLICY "User peut se voir lui-même"
  ON users FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "Admin gère les users du salon"
  ON users FOR ALL
  USING (salon_id = auth.salon_id() AND auth.user_role() = 'admin');

-- ── CLIENTS policies ──────────────────────────────────────
CREATE POLICY "Clients visibles par le salon"
  ON clients FOR SELECT
  USING (salon_id = auth.salon_id());

CREATE POLICY "Clients modifiables par employés"
  ON clients FOR INSERT
  WITH CHECK (salon_id = auth.salon_id());

CREATE POLICY "Clients mis à jour par employés"
  ON clients FOR UPDATE
  USING (salon_id = auth.salon_id());

-- ── QUEUE ENTRIES policies ────────────────────────────────
CREATE POLICY "File visible par le salon"
  ON queue_entries FOR SELECT
  USING (salon_id = auth.salon_id());

-- Lecture publique pour les clients (par slug, sans auth)
CREATE POLICY "File publique en lecture via salon_id"
  ON queue_entries FOR SELECT
  TO anon
  USING (TRUE); -- Filtré par salon_id dans la requête

CREATE POLICY "Employés peuvent modifier la file"
  ON queue_entries FOR ALL
  USING (salon_id = auth.salon_id());

CREATE POLICY "Anonymes peuvent rejoindre la file"
  ON queue_entries FOR INSERT
  TO anon
  WITH CHECK (TRUE); -- Validé côté API

-- ── SUBSCRIPTIONS policies ────────────────────────────────
CREATE POLICY "Abonnements visibles par admin"
  ON subscriptions FOR SELECT
  USING (salon_id = auth.salon_id() AND auth.user_role() = 'admin');

-- ── NOTIFICATIONS policies ────────────────────────────────
CREATE POLICY "Notifications visibles par le salon"
  ON notifications_log FOR SELECT
  USING (salon_id = auth.salon_id());

-- ============================================================
-- 8. FONCTIONS & TRIGGERS
-- ============================================================

-- ── updated_at automatique ─────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salons_updated_at
  BEFORE UPDATE ON salons
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_clients_updated_at
  BEFORE UPDATE ON clients
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Auto-segmentation client ───────────────────────────────
CREATE OR REPLACE FUNCTION update_client_segment()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.visit_count >= 10 AND
     NEW.last_visit > NOW() - INTERVAL '60 days' THEN
    NEW.segment = 'vip';
  ELSIF NEW.last_visit < NOW() - INTERVAL '30 days' THEN
    NEW.segment = 'inactive';
  ELSIF NEW.visit_count >= 2 THEN
    NEW.segment = 'active';
  ELSE
    NEW.segment = 'new';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_client_segment
  BEFORE INSERT OR UPDATE OF visit_count, last_visit ON clients
  FOR EACH ROW EXECUTE FUNCTION update_client_segment();

-- ── Recalcul positions après suppression ──────────────────
CREATE OR REPLACE FUNCTION reorder_queue_positions()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE queue_entries
  SET position = sub.new_pos
  FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY salon_id, date
             ORDER BY joined_at
           ) AS new_pos
    FROM queue_entries
    WHERE salon_id = OLD.salon_id
      AND date = OLD.date
      AND status = 'waiting'
  ) sub
  WHERE queue_entries.id = sub.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reorder_queue
  AFTER DELETE ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION reorder_queue_positions();

-- ── Mise à jour stats client quand service terminé ────────
CREATE OR REPLACE FUNCTION sync_client_stats()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'done' AND OLD.status != 'done' AND NEW.client_id IS NOT NULL THEN
    UPDATE clients
    SET
      visit_count = visit_count + 1,
      total_spent = total_spent + COALESCE(NEW.price, 0),
      last_visit  = NOW()
    WHERE id = NEW.client_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_client_stats
  AFTER UPDATE OF status ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION sync_client_stats();

-- ── Vérification limite plan Free ─────────────────────────
CREATE OR REPLACE FUNCTION check_free_plan_limit()
RETURNS TRIGGER AS $$
DECLARE
  v_plan TEXT;
  v_count INTEGER;
BEGIN
  SELECT plan INTO v_plan FROM salons WHERE id = NEW.salon_id;

  IF v_plan = 'free' THEN
    SELECT COUNT(*) INTO v_count
    FROM queue_entries
    WHERE salon_id = NEW.salon_id
      AND joined_at >= DATE_TRUNC('month', NOW());

    IF v_count >= 50 THEN
      RAISE EXCEPTION 'PLAN_LIMIT: Limite de 50 clients/mois atteinte sur le plan Free';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_free_plan_limit
  BEFORE INSERT ON queue_entries
  FOR EACH ROW EXECUTE FUNCTION check_free_plan_limit();

-- ============================================================
-- 9. VUES ANALYTICS
-- ============================================================

-- Vue stats quotidiennes par salon
CREATE OR REPLACE VIEW v_daily_stats AS
SELECT
  salon_id,
  date,
  COUNT(*)                                    AS total_entries,
  COUNT(*) FILTER (WHERE status = 'done')     AS served,
  COUNT(*) FILTER (WHERE status = 'no_show')  AS no_shows,
  SUM(price) FILTER (WHERE status = 'done')   AS revenue,
  AVG(wait_minutes) FILTER (WHERE status = 'done' AND wait_minutes IS NOT NULL)
                                              AS avg_wait_min,
  MAX(price) FILTER (WHERE status = 'done')   AS max_ticket,
  MIN(joined_at)                              AS first_entry,
  MAX(done_at)                                AS last_done
FROM queue_entries
GROUP BY salon_id, date;

-- Vue file en cours (temps réel)
CREATE OR REPLACE VIEW v_live_queue AS
SELECT
  qe.*,
  s.name  AS salon_name,
  s.slug  AS salon_slug,
  EXTRACT(EPOCH FROM (NOW() - qe.joined_at)) / 60
          AS actual_wait_min
FROM queue_entries qe
JOIN salons s ON s.id = qe.salon_id
WHERE qe.status IN ('waiting', 'called', 'serving')
  AND qe.date = CURRENT_DATE;

-- Vue segmentation clients
CREATE OR REPLACE VIEW v_client_segments AS
SELECT
  salon_id,
  segment,
  COUNT(*)              AS count,
  AVG(visit_count)      AS avg_visits,
  AVG(total_spent)      AS avg_spent,
  COUNT(*) FILTER (WHERE phone IS NOT NULL) AS with_phone
FROM clients
GROUP BY salon_id, segment;

-- Vue heures de pointe (heatmap)
CREATE OR REPLACE VIEW v_peak_hours AS
SELECT
  salon_id,
  EXTRACT(DOW FROM joined_at)  AS day_of_week,   -- 0=dim, 6=sam
  EXTRACT(HOUR FROM joined_at) AS hour_of_day,
  COUNT(*)                     AS entry_count
FROM queue_entries
WHERE joined_at > NOW() - INTERVAL '30 days'
GROUP BY salon_id, day_of_week, hour_of_day
ORDER BY salon_id, day_of_week, hour_of_day;

-- ============================================================
-- 10. DONNÉES DE TEST (optionnel, à désactiver en prod)
-- ============================================================

-- Insérer un salon de démo
INSERT INTO salons (slug, name, phone, address, city, plan) VALUES
  ('salon-teranga', 'Salon Teranga', '+221771234567', 'Rue 10, Médina', 'Dakar', 'starter'),
  ('salon-alpha',   'Salon Alpha',   '+221783456789', 'Av. Cheikh Anta Diop', 'Dakar', 'free')
ON CONFLICT (slug) DO NOTHING;
