#!/bin/bash

set -u 

# --- CONSTANTES E BINÁRIOS ---
ASTERISK_BIN="/usr/sbin/asterisk"
DATE_BIN="/bin/date"
AWK_BIN="/usr/bin/awk"
MV_BIN="/bin/mv"
CHMOD_BIN="/bin/chmod"
FLOCK_BIN="/usr/bin/flock"

# --- CAMINHOS ---
# Ajuste conforme seu ambiente
DIR_OUTPUT="/var/www/html"
ARQUIVO_JSON="$DIR_OUTPUT/monitor.json"
ARQUIVO_JSON_TMP="$DIR_OUTPUT/monitor.json.tmp"
ARQUIVO_HISTORICO="/var/log/asterisk/monitor_historico.log"
CDR_MASTER="/var/log/asterisk/cdr-csv/Master.csv"
LOCK_FILE="/tmp/monitor_asterisk.lock"

# --- DATA E HORA ---
DATA_HOJE=$($DATE_BIN +%Y-%m-%d)
HORA_ATUAL=$($DATE_BIN '+%H:%M')
DATA_COMPLETA=$($DATE_BIN '+%F %T')

# --- 1. LOCK (SINGLETON) ---

exec 200>"$LOCK_FILE"
if ! $FLOCK_BIN -n 200; then
    echo "$DATA_COMPLETA | WARN | Tentativa de execucao simultanea abortada." >> "$ARQUIVO_HISTORICO"
    exit 0
fi

# Garante existência do log
touch "$ARQUIVO_HISTORICO"

# --- 2. MAPA DE CHAMADAS ---
declare -A CHAMADAS_MAP

if [ -f "$CDR_MASTER" ]; then

    while read -r RAMAL QTD; do
        CHAMADAS_MAP["$RAMAL"]=$QTD
    done < <($AWK_BIN -v d="$DATA_HOJE" -F',' '
        # Filtra data (que geralmente está no começo da linha) e status ANSWERED
        index($0, d) && index($0, "ANSWERED") {
            # Verifica apenas a coluna 6 (Destination Channel)
            # Remove aspas se houver e busca padrao PJSIP
            if ($6 ~ /PJSIP\//) {
                split($6, a, "/");    # Divide PJSIP/300-00001
                split(a[2], b, "-");  # Pega o 300 antes do traco
                # Remove aspas duplas caso existam no CSV
                gsub(/"/, "", b[1]);
                count[b[1]]++;
            }
        }
        END { for (r in count) print r, count[r] }
    ' "$CDR_MASTER")
fi

# --- 3. STATUS E GERAÇÃO JSON ---
printf "[\n" > "$ARQUIVO_JSON_TMP"

FIRST=1

# Executa Asterisk UMA VEZ. Se falhar, define variável vazia para não quebrar o script.
RAW_DATA=$($ASTERISK_BIN -rx "pjsip show endpoints" 2>/dev/null | grep "Endpoint:" || true)

while read -r LINE; do
    # Pula linhas vazias
    [ -z "$LINE" ] && continue

    # Extrai apenas o ID do Endpoint (Ramal)
    RAMAL=$(echo "$LINE" | $AWK_BIN '{print $2}')

    # --- VALIDAÇÃO DE SEGURANÇA ---
    # Se o ramal não for numérico (ex: "anonymous", "trunk-oi"), pula.
    if ! [[ "$RAMAL" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # Extrai Status (tudo após o ramal)
    STATUS_RAW=$(echo "$LINE" | $AWK_BIN '{$1=""; $2=""; print $0}' | xargs)

    # Normalização
    if [[ "$STATUS_RAW" == *"Busy"* ]] || [[ "$STATUS_RAW" == *"In use"* ]]; then
        STATUS="Ocupado"; COR="warning"
    elif [[ "$STATUS_RAW" == *"Not in use"* ]] || [[ "$STATUS_RAW" == *"Avail"* ]]; then
        STATUS="Disponivel"; COR="success"
    else
        STATUS="Indisponivel"; COR="danger"
        # Loga falha se não for status desconhecido
        if [[ "$STATUS_RAW" != "Unknown" ]]; then 
             echo "$DATA_COMPLETA | RAMAL $RAMAL | FALHA | Status: $STATUS_RAW" >> "$ARQUIVO_HISTORICO"
        fi
    fi

    QTD_CHAMADAS=${CHAMADAS_MAP["$RAMAL"]:-0}

    # Vírgula JSON
    if [ "$FIRST" -eq 0 ]; then printf ",\n" >> "$ARQUIVO_JSON_TMP"; fi
    FIRST=0

    # Escrita segura
    printf "  {\n    \"ramal\": \"%s\",\n    \"status\": \"%s\",\n    \"cor\": \"%s\",\n    \"chamadas\": \"%s\",\n    \"atualizado\": \"%s\"\n  }" \
      "$RAMAL" "$STATUS" "$COR" "$QTD_CHAMADAS" "$HORA_ATUAL" >> "$ARQUIVO_JSON_TMP"

done <<< "$RAW_DATA"

printf "\n]\n" >> "$ARQUIVO_JSON_TMP"

# --- 4. FINALIZAÇÃO ---
$MV_BIN "$ARQUIVO_JSON_TMP" "$ARQUIVO_JSON"

# Permissões:
# 644 permite que o dono (root) escreva e o grupo/outros (apache) leiam.
$CHMOD_BIN 644 "$ARQUIVO_JSON"



# --- BLOCO GITHUB PAGES ---

# Caminho do seu repositório clonado
REPO_DIR="/opt/monitor-asterisk"

# 1. Copia o JSON E O LOG atualizados para a pasta do git
cp "$ARQUIVO_JSON" "$REPO_DIR/monitor.json"
cp "$ARQUIVO_HISTORICO" "$REPO_DIR/monitor_historico.log"  # <--- LINHA ADICIONADA

# 2. Entra na pasta
cd "$REPO_DIR" || exit

# 3. Git Add, Commit e Push
# Adiciona ambos os arquivos
git add monitor.json monitor_historico.log                   # <--- LINHA ALTERADA
git commit -m "Update: $HORA_ATUAL" || true

# Envia para a nuvem (silenciosamente)
git push origin main > /dev/null 2>&1

# Opcional: Se quiser ver no log que enviou
# echo "$DATA_COMPLETA | GITHUB | Dados enviados com sucesso" >> "$ARQUIVO_HISTORICO"
