#!/usr/bin/env bash
set -euo pipefail

### ====== CONFIG ======
APP_USER="opc"
APP_DIR="/opt/waf-demo"
PORT="8080"                  # troque para 8181 se quiser
HOST="0.0.0.0"
WORKERS="2"
PYTHON_BIN="python3"
SERVICE_NAME="waf-demo"
DEFAULT_BASE_URL="http://172.16.1.93:${PORT}"

### ====== PRECHECKS ======
if [[ $EUID -ne 0 ]]; then
  echo ">> Execute como root: sudo bash $0" >&2
  exit 1
fi
id -u "${APP_USER}" >/dev/null 2>&1 || { echo ">> Usuário ${APP_USER} não existe"; exit 1; }

### ====== PACOTES ======
echo ">> Instalando pacotes..."
dnf -y install ${PYTHON_BIN} ${PYTHON_BIN}-pip git policycoreutils-python-utils firewalld || true
systemctl enable --now firewalld || true

### ====== DIRETÓRIO BASE + DONO ======
echo ">> Criando ${APP_DIR} e ajustando dono para ${APP_USER}..."
mkdir -p "${APP_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

### ====== ÁRVORE DO APP ======
sudo -u "${APP_USER}" install -d "${APP_DIR}/app" "${APP_DIR}/scripts" "${APP_DIR}/postman"

### ====== VENV + DEPENDÊNCIAS ======
echo ">> Criando venv (como ${APP_USER})..."
rm -rf "${APP_DIR}/.venv" 2>/dev/null || true
sudo -u "${APP_USER}" ${PYTHON_BIN} -m venv "${APP_DIR}/.venv"
sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install --upgrade pip
sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install fastapi "uvicorn[standard]" python-multipart

### ====== APP FASTAPI (main única) ======
cat > "${APP_DIR}/app/main.py" <<'PY'
from fastapi import FastAPI, Form, UploadFile, File, Body
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
import logging

app = FastAPI(title="OCI WAF Demo App (one-main)")
logger = logging.getLogger("waf-demo")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

@app.get("/health")
def health():
    return {"status": "ok"}

LANDING = """
<!doctype html><html lang="pt-BR"><meta charset="utf-8">
<title>WAF Demo</title>
<body style="font-family: system-ui; max-width:720px; margin:40px auto">
  <h1>OCI WAF Demo</h1>
  <ul>
    <li><a href="/login">/login</a> (formulário simples, ideal para CAPTCHA)</li>
    <li><a href="/comentarios-form">/comentarios-form</a> (form p/ XSS)</li>
    <li>Endpoints: <code>POST /comentarios</code>, <code>POST /upload</code> (raw), <code>POST /upload-mp</code> (multipart)</li>
    <li>Health: <code>/health</code></li>
  </ul>
  <p style="color:#666">Ambiente de homologação — não usar em produção.</p>
</body></html>
"""
@app.get("/", response_class=HTMLResponse)
def root():
    return LANDING

LOGIN_FORM = """
<!doctype html><html lang="pt-BR"><meta charset="utf-8">
<title>Login</title>
<body style="font-family: system-ui; max-width:480px; margin:40px auto">
  <h1>Login</h1>
  <form action="/login" method="post">
    <label>Usuário<br><input type="text" name="user" required></label><br><br>
    <label>Senha<br><input type="password" name="pass_" required></label><br><br>
    <button type="submit">Entrar</button>
  </form>
  <p style="color:#666">Demo para WAF/CAPTCHA.</p>
  <p><a href="/">Voltar</a></p>
</body></html>
"""
@app.get("/login", response_class=HTMLResponse)
def login_form():
    return LOGIN_FORM

@app.post("/login", response_class=PlainTextResponse)
def login_submit(user: str = Form(...), pass_: str = Form(...)):
    logger.info("Login attempt user=%s", user)
    return f"OK: recebido login de {user}"

XSS_FORM = """
<!doctype html><html lang="pt-BR"><meta charset="utf-8">
<title>XSS Demo</title>
<body style="font-family: system-ui; max-width:480px; margin:40px auto">
  <h1>XSS demo</h1>
  <form action="/comentarios" method="post">
    <label>Mensagem<br><input type="text" name="mensagem" value="<script>alert(1)</script>"></label><br><br>
    <button type="submit">Enviar</button>
  </form>
  <p><a href="/">Voltar</a></p>
</body></html>
"""
@app.get("/comentarios-form", response_class=HTMLResponse)
def comentarios_form():
    return XSS_FORM

@app.post("/comentarios", response_class=HTMLResponse)
async def comentarios(mensagem: str = Form(...)):
    logger.info("XSS test payload: %s", mensagem)
    return f"""<!doctype html><html><body>
      <h1>Comentário recebido</h1>
      <div>Você disse: {mensagem}</div>
      <small>Demo - NÃO usar em produção</small>
    </body></html>"""

@app.post("/upload")
async def upload_raw(raw: bytes = Body(...)):
    size = len(raw)
    logger.info("Upload RAW size bytes: %s", size)
    return {"received_bytes": size}

@app.post("/upload-mp")
async def upload_mp(file: UploadFile = File(...)):
    content = await file.read()
    size = len(content)
    logger.info("Upload MP size bytes: %s", size)
    return {"received_bytes": size}
PY
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app"

### ====== SCRIPTS DE TESTE ======
cat > "${APP_DIR}/scripts/BASE_URL.env" <<EOF
export BASE_URL="${DEFAULT_BASE_URL}"
EOF

cat > "${APP_DIR}/scripts/_lib.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/BASE_URL.env" ]] && source "${SCRIPT_DIR}/BASE_URL.env"
: "${BASE_URL:?Defina BASE_URL em scripts/BASE_URL.env (ex: http://172.16.1.93:8080)}"
BASH

cat > "${APP_DIR}/scripts/xss.sh" <<'BASH'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
curl -i -X POST "$BASE_URL/comentarios" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'mensagem=<script>alert(1)</script>'
BASH

cat > "${APP_DIR}/scripts/sqli.sh" <<'BASH'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
curl -i -X POST "$BASE_URL/login" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "user=admin' OR '1'='1&pass_=x"
BASH

cat > "${APP_DIR}/scripts/bigpost.sh" <<'BASH'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
dd if=/dev/zero bs=1K count=512 status=none | base64 > /tmp/big.txt
curl -i -X POST "$BASE_URL/upload" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @/tmp/big.txt
BASH

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/scripts"
chmod +x "${APP_DIR}/scripts/"*.sh

### ====== FIREWALLD ======
echo ">> Abrindo porta ${PORT}/tcp no firewalld..."
firewall-cmd --permanent --add-port="${PORT}"/tcp
firewall-cmd --reload

### ====== SELINUX ======
echo ">> Ajustando SELinux (http_port_t na porta ${PORT})..."
semanage port -a -t http_port_t -p tcp "${PORT}" || semanage port -m -t http_port_t -p tcp "${PORT}"

### ====== SYSTEMD ENVFILE ======
cat > /etc/sysconfig/${SERVICE_NAME} <<EOF
PORT=${PORT}
HOST=${HOST}
WORKERS=${WORKERS}
APP_MODULE=app.main:app
VENVDIR=${APP_DIR}/.venv
WORKDIR=${APP_DIR}
EOF

### ====== SYSTEMD UNIT ======
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=OCI WAF Demo (FastAPI/Uvicorn)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${APP_DIR}

[Service]
User=${APP_USER}
Group=${APP_USER}
EnvironmentFile=/etc/sysconfig/${SERVICE_NAME}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/uvicorn \$APP_MODULE --host \$HOST --port \$PORT --workers \$WORKERS
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${APP_DIR}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

### ====== START/ENABLE ======
echo ">> Habilitando e iniciando o serviço..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
sleep 1 || true
systemctl --no-pager --full status "${SERVICE_NAME}" || true

### ====== SANITY CHECK ======
echo ">> Teste de saúde:"
curl -sS "${DEFAULT_BASE_URL}/health" || true

cat <<'MSG'

========================================================
✅ Instalação finalizada.

Scripts:
  /opt/waf-demo/scripts/xss.sh
  /opt/waf-demo/scripts/sqli.sh
  /opt/waf-demo/scripts/bigpost.sh

Service:
  sudo systemctl status waf-demo --no-pager
  journalctl -u waf-demo -f

Para testar VIA WAF:
  - Coloque um Load Balancer HTTP/HTTPS em frente ao 172.16.1.93:${PORT}
  - Anexe sua WAF Policy ao LB (Firewall/enforcement point)
  - Ative Body Inspection (ex.: 8192) + ação 403 se exceder
  - Troque BASE_URL.env para o FQDN do LB e rode os scripts

========================================================
MSG
