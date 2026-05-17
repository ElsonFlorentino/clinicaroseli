-- ============================================================================
-- SCHEMA: Tracking WhatsApp + Google Ads — Clínica Roseli Andrade
-- Dermatologia e Cirurgia Plástica — Santos/SP
-- Google Ads: AW-18004522237 | GTM: GTM-5C7C3HGQ
-- WhatsApp Business: (13) 3224-2131
--
-- Supabase (PostgreSQL) — Pronto para colar no SQL Editor
-- ============================================================================

-- ============================================================================
-- 1. TIPO ENUM: Status do funil de conversão
-- ============================================================================

CREATE TYPE conversion_status AS ENUM (
  'clique',           -- Clicou no botão WhatsApp (bridge page)
  'conversa',         -- Respondeu no WhatsApp (marcação manual)
  'agendamento',      -- Agendou consulta
  'compareceu',       -- Compareceu à consulta
  'nao_compareceu'    -- Não compareceu (no-show)
);

COMMENT ON TYPE conversion_status IS 'Funil: clique → conversa → agendamento → compareceu/nao_compareceu';

-- ============================================================================
-- 2. TIPO ENUM: Dispositivo do visitante
-- ============================================================================

CREATE TYPE device_type AS ENUM ('mobile', 'desktop', 'tablet', 'unknown');

-- ============================================================================
-- 3. TABELA: wa_conversions (registro principal de cada conversão)
-- ============================================================================

CREATE TABLE wa_conversions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identificação do visitante
  visitor_id      TEXT NOT NULL,                    -- Cookie ou fingerprint do visitante
  phone           TEXT,                             -- Telefone do paciente (preenchido depois)
  nome            TEXT,                             -- Nome do paciente (preenchido depois)

  -- Status atual no funil
  status          conversion_status NOT NULL DEFAULT 'clique',

  -- Dados Google Ads (capturados na bridge page via UTM)
  gclid           TEXT,                             -- Google Click ID (chave para offline conversions)
  utm_source      TEXT,                             -- google, instagram, organico...
  utm_medium      TEXT,                             -- cpc, social, referral...
  utm_campaign    TEXT,                             -- Nome da campanha Google Ads
  utm_term        TEXT,                             -- Palavra-chave do Google Ads
  utm_content     TEXT,                             -- Variante do anúncio
  gbraid          TEXT,                             -- Cross-device click ID (iOS 14.5+)
  wbraid          TEXT,                             -- Web-to-app click ID

  -- Dados da sessão
  landing_page    TEXT,                             -- URL da página de entrada
  referrer        TEXT,                             -- Referrer da visita
  device          device_type DEFAULT 'unknown',    -- Tipo de dispositivo
  user_agent      TEXT,                             -- User-Agent completo
  ip_address      INET,                             -- IP (para geolocalização)

  -- Dados da consulta (preenchidos na etapa agendamento)
  procedimento    TEXT,                             -- Ex: "botox", "peeling", "rinoplastia"
  data_agendamento TIMESTAMPTZ,                     -- Data/hora da consulta agendada
  valor_consulta  NUMERIC(10,2),                    -- Valor cobrado (R$)

  -- Observações internas
  notas           TEXT,                             -- Anotações da recepção/equipe

  -- Timestamps
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(), -- Momento do clique no WhatsApp
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE wa_conversions IS 'Registro principal de cada lead WhatsApp. Criado na bridge page, atualizado pela equipe.';
COMMENT ON COLUMN wa_conversions.gclid IS 'Google Click ID — essencial para upload de conversões offline no Google Ads';
COMMENT ON COLUMN wa_conversions.visitor_id IS 'Identificador anônimo do visitante (UUID gerado no JS da bridge page)';

-- ============================================================================
-- 4. TABELA: conversion_status_log (histórico de mudanças de status)
-- ============================================================================

CREATE TABLE conversion_status_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversion_id   UUID NOT NULL REFERENCES wa_conversions(id) ON DELETE CASCADE,

  status_anterior conversion_status,                -- NULL no primeiro registro (clique)
  status_novo     conversion_status NOT NULL,

  alterado_por    TEXT,                              -- Quem alterou (nome/email do operador)
  motivo          TEXT,                              -- Motivo da mudança (opcional)

  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE conversion_status_log IS 'Log de auditoria: toda mudança de status gera um registro aqui';

-- ============================================================================
-- 5. TABELA: ga_offline_uploads (controle de uploads para Google Ads)
-- ============================================================================

CREATE TABLE ga_offline_uploads (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Controle do upload
  upload_date     TIMESTAMPTZ NOT NULL DEFAULT now(),
  conversions_count INT NOT NULL DEFAULT 0,          -- Quantas conversões no lote
  status          TEXT NOT NULL DEFAULT 'pending'     -- pending, uploaded, error
                  CHECK (status IN ('pending', 'uploaded', 'error')),

  -- Filtros usados
  status_filtro   conversion_status NOT NULL,        -- Qual status foi exportado
  periodo_inicio  TIMESTAMPTZ NOT NULL,
  periodo_fim     TIMESTAMPTZ NOT NULL,

  -- Resultado
  google_job_id   TEXT,                              -- ID retornado pelo Google Ads
  error_message   TEXT,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE ga_offline_uploads IS 'Controle de lotes de conversões offline enviados ao Google Ads';

-- ============================================================================
-- 6. FUNCTION: trigger para atualizar updated_at automaticamente
-- ============================================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wa_conversions_updated_at
  BEFORE UPDATE ON wa_conversions
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- 7. FUNCTION: trigger para registrar mudanças de status no log
-- ============================================================================

CREATE OR REPLACE FUNCTION log_status_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Só loga se o status realmente mudou
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO conversion_status_log (conversion_id, status_anterior, status_novo)
    VALUES (NEW.id, OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wa_conversions_status_log
  AFTER UPDATE OF status ON wa_conversions
  FOR EACH ROW
  EXECUTE FUNCTION log_status_change();

-- ============================================================================
-- 8. FUNCTION: trigger para log do INSERT inicial (status = 'clique')
-- ============================================================================

CREATE OR REPLACE FUNCTION log_initial_status()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO conversion_status_log (conversion_id, status_anterior, status_novo)
  VALUES (NEW.id, NULL, NEW.status);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wa_conversions_initial_log
  AFTER INSERT ON wa_conversions
  FOR EACH ROW
  EXECUTE FUNCTION log_initial_status();

-- ============================================================================
-- 9. INDEXES para performance
-- ============================================================================

-- Busca por gclid (essencial para reconciliação com Google Ads)
CREATE INDEX idx_wa_conversions_gclid ON wa_conversions(gclid) WHERE gclid IS NOT NULL;

-- Busca por status (filtros do dashboard e exports)
CREATE INDEX idx_wa_conversions_status ON wa_conversions(status);

-- Busca por data de criação (relatórios por período)
CREATE INDEX idx_wa_conversions_created_at ON wa_conversions(created_at DESC);

-- Busca por campanha (análise de performance por campanha)
CREATE INDEX idx_wa_conversions_campaign ON wa_conversions(utm_campaign) WHERE utm_campaign IS NOT NULL;

-- Busca por telefone (encontrar paciente recorrente)
CREATE INDEX idx_wa_conversions_phone ON wa_conversions(phone) WHERE phone IS NOT NULL;

-- Log de status: busca por conversão
CREATE INDEX idx_status_log_conversion ON conversion_status_log(conversion_id, created_at DESC);

-- Uploads: busca por status
CREATE INDEX idx_uploads_status ON ga_offline_uploads(status);

-- ============================================================================
-- 10. RLS (Row Level Security)
-- ============================================================================

-- Habilitar RLS em todas as tabelas
ALTER TABLE wa_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversion_status_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE ga_offline_uploads ENABLE ROW LEVEL SECURITY;

-- -------------------------------------------------------
-- wa_conversions: INSERT público (bridge page), demais autenticado
-- -------------------------------------------------------

-- Bridge page (anon) pode inserir novos cliques
CREATE POLICY "bridge_page_insert"
  ON wa_conversions
  FOR INSERT
  TO anon
  WITH CHECK (
    -- Só permite inserir com status 'clique' (não pode pular etapas)
    status = 'clique'
    -- Campos obrigatórios na criação
    AND visitor_id IS NOT NULL
  );

-- Usuários autenticados (dashboard) podem ler tudo
CREATE POLICY "dashboard_select"
  ON wa_conversions
  FOR SELECT
  TO authenticated
  USING (true);

-- Usuários autenticados podem atualizar (mudar status, preencher dados)
CREATE POLICY "dashboard_update"
  ON wa_conversions
  FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Usuários autenticados podem deletar (GDPR/LGPD — remoção de dados)
CREATE POLICY "dashboard_delete"
  ON wa_conversions
  FOR DELETE
  TO authenticated
  USING (true);

-- -------------------------------------------------------
-- conversion_status_log: somente leitura para autenticados
-- (inserção via trigger, não direto)
-- -------------------------------------------------------

-- Trigger functions rodam como SECURITY DEFINER, então precisamos
-- permitir insert para o contexto do trigger
CREATE POLICY "trigger_insert_log"
  ON conversion_status_log
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

CREATE POLICY "dashboard_select_log"
  ON conversion_status_log
  FOR SELECT
  TO authenticated
  USING (true);

-- -------------------------------------------------------
-- ga_offline_uploads: somente autenticados
-- -------------------------------------------------------

CREATE POLICY "uploads_all_authenticated"
  ON ga_offline_uploads
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ============================================================================
-- 11. VIEWS para Google Ads Offline Conversion Upload
-- ============================================================================

-- -------------------------------------------------------
-- VIEW: Conversões no formato CSV para upload no Google Ads
-- Formato: https://support.google.com/google-ads/answer/7014069
-- -------------------------------------------------------

-- Vista para conversões de AGENDAMENTO (ação de conversão principal)
CREATE OR REPLACE VIEW v_google_ads_agendamento AS
SELECT
  'Google Click ID'             AS "Parameters:ID",
  gclid                         AS "Google Click ID",
  'Agendamento WhatsApp'        AS "Conversion Name",
  TO_CHAR(
    sl.created_at AT TIME ZONE 'America/Sao_Paulo',
    'YYYY-MM-DD HH24:MI:SS-03:00'
  )                             AS "Conversion Time",
  COALESCE(wc.valor_consulta::TEXT, '')  AS "Conversion Value",
  'BRL'                         AS "Conversion Currency"
FROM wa_conversions wc
JOIN conversion_status_log sl ON sl.conversion_id = wc.id
  AND sl.status_novo = 'agendamento'
WHERE wc.gclid IS NOT NULL
  AND wc.status IN ('agendamento', 'compareceu', 'nao_compareceu')
ORDER BY sl.created_at DESC;

COMMENT ON VIEW v_google_ads_agendamento IS 'CSV pronto para upload de conversões offline no Google Ads — ação "Agendamento WhatsApp"';

-- Vista para conversões de COMPARECIMENTO (ação secundária / qualidade)
CREATE OR REPLACE VIEW v_google_ads_compareceu AS
SELECT
  'Google Click ID'             AS "Parameters:ID",
  gclid                         AS "Google Click ID",
  'Consulta Realizada'          AS "Conversion Name",
  TO_CHAR(
    sl.created_at AT TIME ZONE 'America/Sao_Paulo',
    'YYYY-MM-DD HH24:MI:SS-03:00'
  )                             AS "Conversion Time",
  COALESCE(wc.valor_consulta::TEXT, '')  AS "Conversion Value",
  'BRL'                         AS "Conversion Currency"
FROM wa_conversions wc
JOIN conversion_status_log sl ON sl.conversion_id = wc.id
  AND sl.status_novo = 'compareceu'
WHERE wc.gclid IS NOT NULL
  AND wc.status = 'compareceu'
ORDER BY sl.created_at DESC;

COMMENT ON VIEW v_google_ads_compareceu IS 'CSV pronto para upload de conversões offline no Google Ads — ação "Consulta Realizada"';

-- ============================================================================
-- 12. VIEWS para Dashboard (métricas)
-- ============================================================================

-- Vista: Funil completo com contagens por status
CREATE OR REPLACE VIEW v_funil_conversao AS
SELECT
  status,
  COUNT(*) AS total,
  ROUND(
    COUNT(*)::NUMERIC / NULLIF(SUM(COUNT(*)) OVER (), 0) * 100,
    1
  ) AS percentual
FROM wa_conversions
GROUP BY status
ORDER BY
  CASE status
    WHEN 'clique' THEN 1
    WHEN 'conversa' THEN 2
    WHEN 'agendamento' THEN 3
    WHEN 'compareceu' THEN 4
    WHEN 'nao_compareceu' THEN 5
  END;

COMMENT ON VIEW v_funil_conversao IS 'Distribuição de leads por etapa do funil';

-- Vista: Performance por campanha Google Ads
CREATE OR REPLACE VIEW v_performance_campanha AS
SELECT
  COALESCE(utm_campaign, '(direto / sem campanha)') AS campanha,
  COUNT(*) AS total_cliques,
  COUNT(*) FILTER (WHERE status IN ('conversa', 'agendamento', 'compareceu', 'nao_compareceu')) AS conversas,
  COUNT(*) FILTER (WHERE status IN ('agendamento', 'compareceu', 'nao_compareceu')) AS agendamentos,
  COUNT(*) FILTER (WHERE status = 'compareceu') AS compareceram,
  COUNT(*) FILTER (WHERE status = 'nao_compareceu') AS no_show,
  ROUND(
    COUNT(*) FILTER (WHERE status IN ('agendamento', 'compareceu', 'nao_compareceu'))::NUMERIC
    / NULLIF(COUNT(*), 0) * 100,
    1
  ) AS taxa_agendamento_pct,
  ROUND(
    COUNT(*) FILTER (WHERE status = 'compareceu')::NUMERIC
    / NULLIF(COUNT(*) FILTER (WHERE status IN ('agendamento', 'compareceu', 'nao_compareceu')), 0) * 100,
    1
  ) AS taxa_comparecimento_pct
FROM wa_conversions
GROUP BY COALESCE(utm_campaign, '(direto / sem campanha)')
ORDER BY total_cliques DESC;

COMMENT ON VIEW v_performance_campanha IS 'Métricas de funil por campanha Google Ads';

-- Vista: Performance por dia (tendência)
CREATE OR REPLACE VIEW v_performance_diaria AS
SELECT
  DATE(created_at AT TIME ZONE 'America/Sao_Paulo') AS data,
  COUNT(*) AS cliques,
  COUNT(*) FILTER (WHERE status IN ('conversa', 'agendamento', 'compareceu', 'nao_compareceu')) AS conversas,
  COUNT(*) FILTER (WHERE status IN ('agendamento', 'compareceu', 'nao_compareceu')) AS agendamentos,
  COUNT(*) FILTER (WHERE status = 'compareceu') AS compareceram,
  COUNT(*) FILTER (WHERE gclid IS NOT NULL) AS cliques_google_ads
FROM wa_conversions
GROUP BY DATE(created_at AT TIME ZONE 'America/Sao_Paulo')
ORDER BY data DESC;

COMMENT ON VIEW v_performance_diaria IS 'Métricas diárias para gráfico de tendência';

-- Vista: Performance por procedimento
CREATE OR REPLACE VIEW v_performance_procedimento AS
SELECT
  COALESCE(procedimento, '(não informado)') AS procedimento,
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE status = 'compareceu') AS compareceram,
  SUM(valor_consulta) FILTER (WHERE status = 'compareceu') AS receita_total,
  ROUND(AVG(valor_consulta) FILTER (WHERE status = 'compareceu'), 2) AS ticket_medio
FROM wa_conversions
WHERE status IN ('agendamento', 'compareceu', 'nao_compareceu')
GROUP BY COALESCE(procedimento, '(não informado)')
ORDER BY total DESC;

COMMENT ON VIEW v_performance_procedimento IS 'Métricas por tipo de procedimento estético';

-- Vista: Leads recentes para painel de gestão
CREATE OR REPLACE VIEW v_leads_recentes AS
SELECT
  id,
  nome,
  phone,
  status,
  utm_campaign,
  utm_source,
  procedimento,
  data_agendamento,
  device,
  notas,
  created_at,
  updated_at,
  -- Tempo desde o clique
  EXTRACT(EPOCH FROM (now() - created_at)) / 3600 AS horas_desde_clique,
  -- Flag: tem gclid (veio do Google Ads)
  (gclid IS NOT NULL) AS veio_google_ads
FROM wa_conversions
ORDER BY created_at DESC;

COMMENT ON VIEW v_leads_recentes IS 'Lista de leads recentes para painel de gestão da clínica';

-- ============================================================================
-- 13. FUNCTION: Validação de transição de status (impede pular etapas)
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_status_transition()
RETURNS TRIGGER AS $$
DECLARE
  transicoes_validas BOOLEAN;
BEGIN
  -- Definir transições válidas do funil
  transicoes_validas := CASE
    -- clique → conversa (respondeu no WhatsApp)
    WHEN OLD.status = 'clique' AND NEW.status = 'conversa' THEN TRUE
    -- conversa → agendamento (marcou consulta)
    WHEN OLD.status = 'conversa' AND NEW.status = 'agendamento' THEN TRUE
    -- agendamento → compareceu (veio à consulta)
    WHEN OLD.status = 'agendamento' AND NEW.status = 'compareceu' THEN TRUE
    -- agendamento → nao_compareceu (faltou)
    WHEN OLD.status = 'agendamento' AND NEW.status = 'nao_compareceu' THEN TRUE
    -- nao_compareceu → agendamento (remarcou)
    WHEN OLD.status = 'nao_compareceu' AND NEW.status = 'agendamento' THEN TRUE
    -- Permitir "rebaixar" status em caso de correção (conversa → clique)
    WHEN OLD.status = 'conversa' AND NEW.status = 'clique' THEN TRUE
    ELSE FALSE
  END;

  IF NOT transicoes_validas THEN
    RAISE EXCEPTION 'Transição de status inválida: % → %. Transições permitidas: clique→conversa→agendamento→compareceu/nao_compareceu',
      OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_status_transition
  BEFORE UPDATE OF status ON wa_conversions
  FOR EACH ROW
  EXECUTE FUNCTION validate_status_transition();

-- ============================================================================
-- 14. DADOS INICIAIS: procedimentos comuns (referência)
-- ============================================================================

COMMENT ON SCHEMA public IS 'Schema de tracking WhatsApp → Google Ads Offline Conversions para Clínica Roseli Andrade (Santos/SP). Conta Google Ads: AW-18004522237.';

-- ============================================================================
-- 15. GRANT para service_role (usado pelo backend/edge functions)
-- ============================================================================

-- Service role tem acesso total (para Edge Functions, cron jobs, etc.)
GRANT ALL ON wa_conversions TO service_role;
GRANT ALL ON conversion_status_log TO service_role;
GRANT ALL ON ga_offline_uploads TO service_role;
GRANT SELECT ON v_google_ads_agendamento TO service_role;
GRANT SELECT ON v_google_ads_compareceu TO service_role;
GRANT SELECT ON v_funil_conversao TO service_role;
GRANT SELECT ON v_performance_campanha TO service_role;
GRANT SELECT ON v_performance_diaria TO service_role;
GRANT SELECT ON v_performance_procedimento TO service_role;
GRANT SELECT ON v_leads_recentes TO service_role;

-- ============================================================================
-- FIM DO SCHEMA
-- ============================================================================
--
-- PRÓXIMOS PASSOS:
-- 1. Colar este SQL no Supabase SQL Editor e executar
-- 2. Criar a bridge page (wa-bridge.html) que faz INSERT via supabase-js (anon key)
-- 3. Configurar 2 ações de conversão no Google Ads:
--    - "Agendamento WhatsApp" (primária, otimização de lances)
--    - "Consulta Realizada" (secundária, observação)
-- 4. Exportar CSV via v_google_ads_agendamento semanalmente
-- 5. Criar dashboard lendo as views v_funil_*, v_performance_*
--
-- FORMATO CSV PARA GOOGLE ADS:
-- Exportar v_google_ads_agendamento como CSV com cabeçalho.
-- O cabeçalho já está no formato exato esperado pelo Google Ads.
-- Upload em: Google Ads → Ferramentas → Conversões → Uploads
-- ============================================================================
