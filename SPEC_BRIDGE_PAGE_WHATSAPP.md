# Bridge Page WhatsApp — Especificacao Tecnica Completa

**Projeto:** Roseli Andrade — roseliandrade.com.br
**Data:** 2026-05-17
**Status:** Spec pronta para implementacao

---

## 1. Visao Geral do Fluxo

```
Google Ads → roseliandrade.com.br (gclid salvo no cookie pelo Conversion Linker)
                    ↓
         Lead clica no WhatsApp (botao CTA ou widget Chaty)
                    ↓
         GTM intercepta e redireciona para Bridge Page
                    ↓
         /wa.html?origem=home (ou /contato, etc.)
                    ↓
         Bridge Page:
           1. Le gclid do cookie _gcl_aw
           2. Le UTMs do cookie/URL
           3. Gera protocolo RA-XXXXXX (6 chars)
           4. Salva no Supabase via REST API
           5. Dispara gtag conversion (Google Ads)
           6. Redireciona para wa.me com protocolo na mensagem
                    ↓
         WhatsApp abre com mensagem pre-preenchida:
         "Ola, gostaria de agendar uma consulta. (ref: RA-3K7X9)"
```

---

## 2. Captura do gclid no Site Principal

**Ja esta funcionando.** O Conversion Linker (tag existente no GTM-5C7C3HGQ) faz isso automaticamente:

- Quando o lead chega via Google Ads com `?gclid=xxx` na URL
- O Conversion Linker salva no cookie `_gcl_aw` com formato: `GCL.timestamp.gclid_value`
- Cookie dura 90 dias, first-party domain
- Nenhuma alteracao necessaria nesta etapa

### Como extrair o gclid do cookie no JS

```javascript
function getGclid() {
  var match = document.cookie.match(/_gcl_aw=GCL\.\d+\.([^;]+)/);
  return match ? match[1] : null;
}
```

---

## 3. Captura de UTMs no Site Principal

Precisamos adicionar uma tag no GTM para salvar UTMs em cookies quando o lead chega ao site. Isso permite que a Bridge Page saiba de qual campanha veio o lead, mesmo que ele navegue por varias paginas antes de clicar no WhatsApp.

### Tag GTM: "UTM Cookie Writer" (Custom HTML)

**Trigger:** All Pages (pageview)

```html
<script>
(function() {
  var params = new URLSearchParams(window.location.search);
  var utms = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'];

  // So escreve se tem pelo menos 1 UTM na URL (evita sobrescrever com vazio)
  var hasUtm = utms.some(function(u) { return params.has(u); });
  if (!hasUtm) return;

  utms.forEach(function(u) {
    var val = params.get(u);
    if (val) {
      document.cookie = u + '=' + encodeURIComponent(val) +
        ';max-age=2592000;path=/;SameSite=Lax';
    }
  });
})();
</script>
```

**Nota:** max-age=2592000 = 30 dias. Suficiente para o ciclo de decisao de uma clinica.

---

## 4. Bridge Page — Codigo Completo

**Arquivo:** `wa.html`
**Hosting:** GitHub Pages (repo clinicaroseli) ou Supabase Storage
**URL final:** `https://{usuario}.github.io/clinicaroseli/wa.html`
(ou subdominio customizado se preferir)

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex, nofollow">
<title>Redirecionando para WhatsApp...</title>

<!-- Google tag (gtag.js) — necessario para disparar conversao -->
<script async src="https://www.googletagmanager.com/gtag/js?id=AW-18004522237"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'AW-18004522237');
</script>

<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: Arial, sans-serif;
  background: #f5f5f5;
  color: #333;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  text-align: center;
  padding: 20px;
}
.container {
  max-width: 400px;
}
.spinner {
  width: 48px; height: 48px;
  border: 4px solid rgba(37, 211, 102, 0.2);
  border-top-color: #25D366;
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
  margin: 0 auto 24px;
}
@keyframes spin { to { transform: rotate(360deg); } }
h1 { font-size: 20px; margin-bottom: 8px; color: #222; }
p { font-size: 14px; color: #666; margin-bottom: 16px; }
a { color: #25D366; text-decoration: underline; }
.protocolo {
  font-family: monospace;
  font-size: 18px;
  font-weight: bold;
  color: #25D366;
  background: #e8f5e9;
  padding: 8px 16px;
  border-radius: 8px;
  display: inline-block;
  margin-bottom: 16px;
}
</style>
</head>
<body>

<div class="container">
  <div class="spinner"></div>
  <h1>Abrindo WhatsApp...</h1>
  <p>Voce sera redirecionado em instantes.</p>
  <div class="protocolo" id="protocolo-display"></div>
  <p><a href="#" id="fallback-link">Clique aqui se nao redirecionar</a></p>
</div>

<script>
(function() {
  // ============================================================
  // CONFIGURACAO
  // ============================================================
  var WHATSAPP_NUMBER = '551332242131';
  var SUPABASE_URL    = 'https://SEU_PROJETO.supabase.co';
  var SUPABASE_ANON   = 'SUA_ANON_KEY_AQUI';
  // ============================================================

  // 1. Ler gclid do cookie _gcl_aw (salvo pelo Conversion Linker)
  function getGclid() {
    var match = document.cookie.match(/_gcl_aw=GCL\.\d+\.([^;]+)/);
    return match ? match[1] : null;
  }

  // 2. Ler UTM de cookie (salvo pela tag UTM Cookie Writer no GTM)
  function getCookie(name) {
    var match = document.cookie.match(new RegExp('(?:^|;\\s*)' + name + '=([^;]*)'));
    return match ? decodeURIComponent(match[1]) : null;
  }

  // 3. Ler parametro da URL (query string da bridge page)
  function getParam(name) {
    var params = new URLSearchParams(window.location.search);
    return params.get(name);
  }

  // 4. Gerar protocolo alfanumerico de 6 caracteres
  //    Formato: RA-XXXXXX (prefixo RA = Roseli Andrade)
  function gerarProtocolo() {
    var chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // sem I/O/0/1 (evitar confusao)
    var codigo = '';
    for (var i = 0; i < 6; i++) {
      codigo += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return 'RA-' + codigo;
  }

  // 5. Montar dados
  var protocolo    = gerarProtocolo();
  var gclid        = getGclid();
  var utm_source   = getCookie('utm_source')   || getParam('utm_source')   || 'direto';
  var utm_medium   = getCookie('utm_medium')   || getParam('utm_medium')   || null;
  var utm_campaign = getCookie('utm_campaign') || getParam('utm_campaign') || null;
  var utm_term     = getCookie('utm_term')     || getParam('utm_term')     || null;
  var pagina_origem = getParam('origem')       || document.referrer        || 'desconhecida';

  // 6. Exibir protocolo na tela
  document.getElementById('protocolo-display').textContent = protocolo;

  // 7. Montar URL do WhatsApp com mensagem + protocolo
  var mensagem = 'Ola, gostaria de agendar uma consulta.\n(ref: ' + protocolo + ')';
  var waUrl = 'https://wa.me/' + WHATSAPP_NUMBER + '?text=' + encodeURIComponent(mensagem);

  // 8. Setar link de fallback
  document.getElementById('fallback-link').href = waUrl;

  // 9. Salvar no Supabase via REST API (tabela: wa_conversoes)
  var payload = {
    protocolo:      protocolo,
    gclid:          gclid,
    utm_source:     utm_source,
    utm_medium:     utm_medium,
    utm_campaign:   utm_campaign,
    utm_term:       utm_term,
    pagina_origem:  pagina_origem,
    user_agent:     navigator.userAgent,
    created_at:     new Date().toISOString()
  };

  fetch(SUPABASE_URL + '/rest/v1/wa_conversoes', {
    method: 'POST',
    headers: {
      'Content-Type':  'application/json',
      'apikey':        SUPABASE_ANON,
      'Authorization': 'Bearer ' + SUPABASE_ANON,
      'Prefer':        'return=minimal'
    },
    body: JSON.stringify(payload)
  }).catch(function(err) {
    // Nao bloqueia o redirect se o Supabase falhar
    console.warn('Supabase save failed:', err);
  });

  // 10. Disparar conversao Google Ads
  //     Label: i7tcCK30hJwcEP3pnIlD (WhatsApp - Clique)
  //     Mas agora COM o protocolo como transaction_id para reconciliacao
  gtag('event', 'conversion', {
    'send_to':       'AW-18004522237/i7tcCK30hJwcEP3pnIlD',
    'transaction_id': protocolo
  });

  // 11. Redirecionar apos 800ms (tempo para gtag + Supabase enviarem)
  setTimeout(function() {
    window.location.href = waUrl;
  }, 800);

})();
</script>

</body>
</html>
```

---

## 5. Supabase — Tabela `wa_conversoes`

### DDL (criar no SQL Editor do Supabase)

```sql
CREATE TABLE wa_conversoes (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  protocolo     TEXT NOT NULL UNIQUE,
  gclid         TEXT,
  utm_source    TEXT DEFAULT 'direto',
  utm_medium    TEXT,
  utm_campaign  TEXT,
  utm_term      TEXT,
  pagina_origem TEXT,
  user_agent    TEXT,
  status        TEXT DEFAULT 'clique',  -- clique | conversa | agendado | compareceu
  notas         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Index para busca rapida por protocolo (o atendente pesquisa por isso)
CREATE INDEX idx_wa_conversoes_protocolo ON wa_conversoes (protocolo);

-- Index para filtrar por data
CREATE INDEX idx_wa_conversoes_created ON wa_conversoes (created_at DESC);

-- RLS: permitir INSERT anonimo (bridge page usa anon key)
ALTER TABLE wa_conversoes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_insert_wa_conversoes"
  ON wa_conversoes
  FOR INSERT
  TO anon
  WITH CHECK (true);

-- RLS: leitura apenas para authenticated (dashboard interno)
CREATE POLICY "authenticated_select_wa_conversoes"
  ON wa_conversoes
  FOR SELECT
  TO authenticated
  USING (true);

-- RLS: update apenas para authenticated (mudar status)
CREATE POLICY "authenticated_update_wa_conversoes"
  ON wa_conversoes
  FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Trigger para updated_at automatico
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wa_conversoes_updated
  BEFORE UPDATE ON wa_conversoes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();
```

### Politicas de seguranca (RLS)

| Role | SELECT | INSERT | UPDATE | DELETE |
|------|--------|--------|--------|--------|
| anon | NAO | SIM | NAO | NAO |
| authenticated | SIM | SIM | SIM | NAO |

**Justificativa:** A bridge page roda no browser do lead com a anon key, entao precisa de INSERT anonimo. Leitura e update (mudar status para "agendado") sao feitos pelo dashboard interno, autenticado.

---

## 6. Alteracoes no GTM (GTM-5C7C3HGQ)

### 6.1 Nova Tag: "UTM Cookie Writer"

| Campo | Valor |
|-------|-------|
| Tipo | Custom HTML |
| Trigger | All Pages |
| Codigo | (ver secao 3 acima) |

### 6.2 Modificar Tag: "WhatsApp Conversao"

**Estado atual:** A tag dispara `gtag('event', 'conversion', ...)` quando o lead clica em link com `wa.me` ou `whatsapp.com`.

**Mudanca:** Em vez de disparar a conversao direto, agora o clique vai redirecionar para a bridge page. A conversao sera disparada LA (com protocolo).

**Opcao A — Remover a tag "WhatsApp Conversao" do GTM**
A bridge page assume a responsabilidade de disparar a conversao. Mais limpo.

**Opcao B — Manter a tag mas sem a conversao**
Usar a tag so para o redirect. Menos arriscado.

**Recomendacao: Opcao A** (remover a tag de conversao do GTM, a bridge page faz tudo).

### 6.3 Nova Tag: "WhatsApp Bridge Redirect" (Custom HTML)

**Trigger:** Link Click onde Click URL contem `wa.me` OU `whatsapp.com`
(mesmos triggers existentes: "WhatsApp Link Click" e "Chaty Widget Click")

```html
<script>
(function() {
  // Capturar a pagina de origem (slug)
  var origem = window.location.pathname.replace(/^\/|\/$/g, '') || 'home';

  // URL da bridge page
  var bridgeUrl = 'https://SEU_USUARIO.github.io/clinicaroseli/wa.html?origem=' +
    encodeURIComponent(origem);

  // Prevenir o click original de abrir o WhatsApp
  // e redirecionar para a bridge page
  if (window.event) {
    window.event.preventDefault();
  }

  window.location.href = bridgeUrl;
})();
</script>
```

**IMPORTANTE:** Para que o `preventDefault()` funcione, o trigger precisa ser configurado como:

| Campo | Valor |
|-------|-------|
| Tipo do trigger | Click - Just Links |
| "Wait for Tags" | ATIVADO (checked) |
| "Max wait time" | 2000ms |
| "Check Validation" | ATIVADO |
| Condicao | Click URL contem `wa.me` OU Click URL contem `whatsapp.com` |

Isso faz o GTM interceptar o clique, esperar a tag executar, e so entao seguir (mas como redirecionamos, o link original nunca abre).

### 6.4 Alternativa mais simples: Tag Listener no GTM

Se a abordagem acima der problemas com o Enfold/Chaty, uma alternativa mais robusta e usar um listener global:

**Tag: "WA Link Interceptor" (Custom HTML), trigger: All Pages**

```html
<script>
document.addEventListener('click', function(e) {
  var link = e.target.closest('a[href*="wa.me"], a[href*="whatsapp.com"]');
  if (!link) return;

  e.preventDefault();
  e.stopPropagation();

  var origem = window.location.pathname.replace(/^\/|\/$/g, '') || 'home';
  var bridgeUrl = 'https://SEU_USUARIO.github.io/clinicaroseli/wa.html?origem=' +
    encodeURIComponent(origem);

  window.location.href = bridgeUrl;
}, true); // true = capture phase, intercepta antes de qualquer outro handler
</script>
```

**Vantagem:** Funciona com qualquer tipo de botao/widget, independente de como o Enfold ou Chaty renderizam os links. O `capture: true` garante que intercepta antes de outros event listeners.

---

## 7. Mensagem no WhatsApp

### Formato da mensagem pre-preenchida

```
Ola, gostaria de agendar uma consulta.
(ref: RA-3K7X9)
```

### O que o atendente ve

Quando a mensagem chega no WhatsApp Business:

```
[+55 13 9XXXX-XXXX]
Ola, gostaria de agendar uma consulta.
(ref: RA-3K7X9)
```

### Fluxo do atendente

1. Recebe a mensagem com o protocolo `RA-3K7X9`
2. Atende normalmente
3. Se o lead agendar: marca o status no Supabase (ou planilha)
4. Se o lead comparecer: marca como "compareceu"

### Reconciliacao com Google Ads

Semanal (ou automatica na Fase 3):

1. Exportar do Supabase os protocolos com status = "agendado" ou "compareceu"
2. Cada registro tem o `gclid` associado
3. Importar no Google Ads como conversao offline:
   - `Google Click ID` = gclid
   - `Conversion Name` = "Agendamento WhatsApp" (nova acao de conversao)
   - `Conversion Time` = data do agendamento
   - `Conversion Value` = valor da consulta (opcional)

---

## 8. Checklist de Implementacao

### Fase 1: Bridge Page + GTM (1 semana)

- [ ] Criar projeto Supabase (free tier)
- [ ] Executar DDL da tabela `wa_conversoes`
- [ ] Substituir `SUPABASE_URL` e `SUPABASE_ANON` no `wa.html`
- [ ] Fazer deploy do `wa.html` (GitHub Pages)
- [ ] Testar acesso direto a bridge page e verificar no Supabase se o registro chegou
- [ ] Adicionar tag "UTM Cookie Writer" no GTM
- [ ] Adicionar tag "WA Link Interceptor" no GTM
- [ ] Remover (ou pausar) a tag "WhatsApp Conversao" atual
- [ ] Publicar container GTM
- [ ] Testar fluxo completo: Google Ads → site → clicar WhatsApp → bridge page → WhatsApp
- [ ] Verificar: protocolo aparece na mensagem do WhatsApp
- [ ] Verificar: registro no Supabase com gclid preenchido
- [ ] Verificar: conversao no Google Ads com transaction_id

### Fase 2: Dashboard + Reconciliacao (semana 2-3)

- [ ] Criar dashboard simples no Supabase (ou HTML statico lendo a API)
- [ ] Configurar acao de conversao offline no Google Ads ("Agendamento WhatsApp")
- [ ] Criar script de exportacao CSV do Supabase
- [ ] Testar upload manual de conversao offline no Google Ads
- [ ] Treinar atendente para identificar e registrar protocolo

### Fase 3: Automacao (opcional, semana 4+)

- [ ] WhatsApp Business API para detectar mensagens recebidas
- [ ] Webhook para atualizar status no Supabase automaticamente
- [ ] Upload automatico de conversoes offline no Google Ads via API

---

## 9. Pontos de Atencao

### Seguranca

- A `anon key` do Supabase e exposta no frontend. Isso e esperado e seguro porque:
  - RLS restringe anon a INSERT apenas
  - Nao e possivel ler, atualizar ou deletar dados
  - A anon key nao da acesso administrativo
- NUNCA colocar a `service_role key` no frontend

### Performance

- Bridge page leve (~5KB), carrega em <200ms
- Delay de 800ms antes do redirect (tempo para gtag + fetch)
- Se o fetch para o Supabase falhar, o redirect acontece normalmente (`.catch` nao bloqueia)

### Compatibilidade

- Funciona em mobile e desktop
- `wa.me` abre o app WhatsApp no mobile e WhatsApp Web no desktop
- Cookie `_gcl_aw` so existe se o lead veio via Google Ads (se veio organico, gclid sera null)

### CORS

- Supabase REST API permite CORS de qualquer origem por padrao
- Se hospedar em GitHub Pages (dominio diferente), funciona sem configuracao extra

### Widget Chaty

- O interceptor com `capture: true` funciona mesmo com o widget Chaty
- Chaty renderiza links `web.whatsapp.com/send` — o seletor `a[href*="whatsapp.com"]` pega isso

---

## 10. Arquitetura de Arquivos

```
clinicaroseli/
├── wa.html                              ← Bridge Page (deploy via GitHub Pages)
├── APRESENTACAO_TRACKING_WHATSAPP.html  ← Apresentacao para cliente (existente)
├── SPEC_BRIDGE_PAGE_WHATSAPP.md         ← Este documento
└── supabase/
    └── wa_conversoes.sql                ← DDL da tabela
```

---

## 11. Resumo das Alteracoes por Sistema

| Sistema | O que muda | Risco |
|---------|-----------|-------|
| **Site WordPress** | NADA (zero alteracoes no site) | Nenhum |
| **GTM** | +2 tags novas, -1 tag removida (ou pausada) | Baixo (reversivel) |
| **Google Ads** | Conversao passa a ter `transaction_id` | Nenhum (melhoria) |
| **Supabase** | Novo projeto + tabela | Nenhum (isolado) |
| **GitHub Pages** | 1 arquivo HTML | Nenhum |
| **WhatsApp** | Mensagem ganha protocolo | Nenhum (estetico) |
