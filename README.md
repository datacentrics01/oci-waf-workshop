# OCI WAF Workshop — Etapa 2 (XSS / SQLi / POST grande)

Servidor de demonstração (FastAPI/Uvicorn) para validar **OCI WAF**: bloquear XSS/SQLi e **corpos grandes** (body inspection), observar métricas/logs e praticar *tuning* com exclusões.

## Arquitetura de teste (resumo)

```
Cliente (curl/Postman/JMeter)
        │
   (LB HTTP/HTTPS)  ← WAF Policy anexada (enforcement point)
        │
   App demo (FastAPI/Uvicorn) na porta 8080
```

> O WAF da OCI **atua no Load Balancer HTTP/HTTPS** (não suporta NLB/TCP). Para que os testes contem no WAF, aponte os requests para o **endpoint do LB** com a **WAF Policy** anexada.

---

## 1) Requisitos

- Oracle Linux 8/9 com `python3`, `pip`, `git`, `firewalld` e utilitários SELinux.  
- Acesso a um **Load Balancer HTTP/HTTPS** na OCI (para validar pelo WAF).  
- Opcional: JMeter ou outra ferramenta de carga.

**Portas/segurança na VM**  
Abra a porta **8080/tcp** no firewalld e, se SELinux estiver *Enforcing*, associe a porta ao tipo `http_port_t`. Exemplos:  
```bash
sudo firewall-cmd --permanent --add-port=8080/tcp && sudo firewall-cmd --reload
sudo semanage port -a -t http_port_t -p tcp 8080 || sudo semanage port -m -t http_port_t -p tcp 8080
```

---

## 2) Instalação rápida (script “cola e roda”)

No host (como root):

```bash
curl -fsSL -o install_waf_demo.sh https://example.invalid/install_waf_demo.sh
sudo bash install_waf_demo.sh
```

O script cria a árvore em `/opt/waf-demo`, venv, instala **FastAPI + Uvicorn** e **python-multipart** (obrigatório para uploads multipart), escreve os **scripts de teste**, abre firewall, ajusta SELinux, e instala o **serviço systemd** `waf-demo` (starta no boot).

> Se preferir subir manualmente, rode:  
> `source /opt/waf-demo/.venv/bin/activate && uvicorn app.main:app --host 0.0.0.0 --port 8080`

---

## 3) Serviço (systemd)

- Ver status / logs:
  ```bash
  sudo systemctl status waf-demo --no-pager
  journalctl -u waf-demo -f
  ```
- O unit usa **caminho absoluto** no `ExecStart` e `EnvironmentFile` para variáveis.

---

## 4) Endpoints do app

- `GET /health` — verificação simples.  
- `POST /comentarios` — ecoa `mensagem` (simula **XSS**).  
- `POST /login` — simula **SQLi** (loga *pseudo-query*).  
- `POST /upload` — recebe **raw body** (ideal para **--data-binary**).  
- `POST /upload-mp` — recebe **multipart** (`-F file=@...`).

Uploads multipart exigem `python-multipart` instalado, como na documentação do FastAPI.

---

## 5) Scripts de teste

Após instalar, edite `scripts/BASE_URL.env`:

```bash
export BASE_URL="http://172.16.1.93:8080"
# (para validar o WAF, troque para https://<seu-lb-ou-dominio>)
```

Rode:

```bash
/opt/waf-demo/scripts/xss.sh
/opt/waf-demo/scripts/sqli.sh
/opt/waf-demo/scripts/bigpost.sh
```

O `bigpost.sh` envia ~512 KiB (base64) via `--data-binary` para `/upload`.

---

## 6) Configurar o **WAF** para bloquear **“big POST”**

### 6.1 Console (mais rápido)

1) Abra sua **WAF Policy** → **Request protection** → *Edit rule*.  
2) **Enable body inspection** e defina:  
   - **Maximum number of bytes allowed**: `0–8192` (limite por tenancy).  
   - **Action taken if limit has been exceeded**: selecione sua **ação 403** (RETURN_HTTP_RESPONSE).  
   *(Apenas inspecionar até o limite não bloqueia; para bloquear, configure a ação de excedente.)*

3) Garanta que a policy está **anexada ao Load Balancer** (“Add firewalls” / enforcement point). Testes devem ir para o **endpoint do LB**, não para o IP do app.

### 6.2 Terraform (exemplo mínimo)

```hcl
resource "oci_waf_web_app_firewall_policy" "waf" {
  compartment_id = var.compartment_ocid
  display_name   = "waf-hml-policy"

  actions {
    name = "BLOCK_403"
    type = "RETURN_HTTP_RESPONSE"
    code = 403
    body { type = "TEXT_HTML", text = "<h1>403</h1><p>Bloqueado pelo WAF.</p>" }
  }

  request_protection {
    body_inspection_size_limit_in_bytes             = 8192
    body_inspection_size_limit_exceeded_action_name = "BLOCK_403"
  }
}

resource "oci_waf_web_app_firewall" "attach" {
  compartment_id             = var.compartment_ocid
  display_name               = "waf-attach"
  backend_type               = "LOAD_BALANCER"
  load_balancer_id           = var.lb_ocid
  web_app_firewall_policy_id = oci_waf_web_app_firewall_policy.waf.id
}
```

> O **campo de limite + ação ao exceder** implementa o bloqueio por tamanho de corpo; o máximo efetivo é **8192 bytes**.

---

## 7) Testes via WAF (esperado: **403**)

Crie um payload acima do limite e poste **no LB**:

```bash
head -c 9001 /dev/zero > /tmp/over8k.bin
curl -i -X POST https://<LB>/upload   -H 'Content-Type: application/octet-stream'   --data-binary @/tmp/over8k.bin
```

Com o limite em **8192** e **ação 403** configurada, a resposta deve ser **403**.

---

## 8) Observabilidade (métricas e logs)

- **Métricas do WAF**: namespace **`oci_waf`** no Monitoring (Metrics/Alarms). Crie gráficos/alertas para *Blocked Requests*, *Allowed Requests*, *Latency*, etc.  
- **Logs do WAF**: use o Logging para ver *rule matches*, *requestId* e ações aplicadas.

---

## 9) Tuning / Exclusões (reduzindo falsos positivos)

- Ao ajustar a **Request Protection**, prefira **exclusions cirúrgicas** (por *argument*, *cookie*, *path*, *método*) em vez de desabilitar capacidades inteiras. Valide com métricas/logs após cada mudança.

---

## 10) Dúvidas comuns

- **Estou testando e recebo 200 OK em vez de 403**  
  → Você está chamando **direto o app** (ex.: `http://172.16.1.93:8080`). O WAF só atua no **LB**; aponte seus `curl`/Postman para o **endpoint do LB** com a policy anexada.

- **Uploads multipart não funcionam**  
  → Garanta que `python-multipart` está instalado (exigido pelo FastAPI para `File(...)`).

- **Serviço systemd não sobe**  
  → Confirme `ExecStart` com **caminho absoluto** e variáveis simples (`$PORT`), e `WorkingDirectory` absoluto.

---

## 11) Licença

Este repositório é para fins de workshop e demonstração. Não usar em produção sem revisão de segurança.
