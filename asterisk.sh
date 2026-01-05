#!/bin/bash
# /usr/local/bin/monitor_asterisk.sh

set -u

DIA_SEMANA=$(date +%u)

if [ "$DIA_SEMANA" -gt 5 ]; then

    exit 0
fi

# --- 1. CONFIGURAÇÃO DE RAMAIS ---
# Formato: ["NUMERO"]="NOME_DO_USUARIO|INICIO_TURNO|FIM_TURNO"
declare -A CONFIG
CONFIG["305"]="Gabriel Paixão|0705|1555"
CONFIG["303"]="Ian Silva|0705|1555"
CONFIG["300"]="Raiane Mendes|1330|2130"
CONFIG["302"]="Lorrana Silva|1330|2130"
CONFIG["301"]="Lucas Yuri|1330|2130"

# --- CONSTANTES ---
ASTERISK_BIN="/usr/sbin/asterisk"
DATE_BIN="/bin/date"
AWK_BIN="/usr/bin/awk"
FLOCK_BIN="/usr/bin/flock"

# --- CAMINHOS ---
DIR_OUTPUT="/var/www/html" 
ARQUIVO_JSON="$DIR_OUTPUT/monitor.json"
ARQUIVO_JSON_TMP="$DIR_OUTPUT/monitor.json.tmp"
ARQUIVO_HISTORICO="/var/log/asterisk/monitor_historico.log"
LOCK_FILE="/tmp/monitor_asterisk.lock"
REPO_DIR="/opt/monitor-asterisk" 

# --- LOCK ---
exec 200>"$LOCK_FILE"
if ! $FLOCK_BIN -n 200; then exit 0; fi

# --- DATA E HORA ---
HORA_ATUAL_STR=$($DATE_BIN '+%H:%M')
HORA_ATUAL_NUM=$($DATE_BIN '+%H%M') # Ex: 1430
DATA_COMPLETA=$($DATE_BIN '+%F %T')

# --- 2. LOOP PRINCIPAL ---
printf "[\n" > "$ARQUIVO_JSON_TMP"
FIRST=1

for RAMAL in "${!CONFIG[@]}"; do
    IFS='|' read -r NOME INICIO FIM <<< "${CONFIG[$RAMAL]}"

    # Verifica Horário de Turno
    if (( 10#$HORA_ATUAL_NUM < 10#$INICIO )) || (( 10#$HORA_ATUAL_NUM > 10#$FIM )); then
        STATUS="OFF"
        COR="secondary"
    else

        STATUS_RAW=$($ASTERISK_BIN -rx "pjsip show endpoint $RAMAL" 2>/dev/null | grep " Endpoint:" | $AWK_BIN '{$1=""; $2=""; print $0}' | xargs)
        
        if [[ "$STATUS_RAW" == *"Busy"* ]] || [[ "$STATUS_RAW" == *"In use"* ]]; then
            STATUS="Ocupado"; COR="warning"
        elif [[ "$STATUS_RAW" == *"Not in use"* ]] || [[ "$STATUS_RAW" == *"Avail"* ]]; then
            STATUS="Disponivel"; COR="success"
        else
            STATUS="Indisponivel"; COR="danger"
            

            if [ ! -z "$STATUS_RAW" ]; then
                echo "$DATA_COMPLETA | RAMAL $RAMAL ($NOME) | FALHA | Status: Indisponivel" >> "$ARQUIVO_HISTORICO"
            fi
        fi
    fi


    QTD_RX="0"
    QTD_TX="0"

    # Escreve no JSON
    if [ "$FIRST" -eq 0 ]; then printf ",\n" >> "$ARQUIVO_JSON_TMP"; fi
    FIRST=0

    printf "  {\n    \"ramal\": \"%s\",\n    \"nome\": \"%s\",\n    \"status\": \"%s\",\n    \"cor\": \"%s\",\n    \"rx\": \"%s\",\n    \"tx\": \"%s\",\n    \"atualizado\": \"%s\"\n  }" \
      "$RAMAL" "$NOME" "$STATUS" "$COR" "$QTD_RX" "$QTD_TX" "$HORA_ATUAL_STR" >> "$ARQUIVO_JSON_TMP"
done

printf "\n]\n" >> "$ARQUIVO_JSON_TMP"

# --- 3. FINALIZAÇÃO ---
mv "$ARQUIVO_JSON_TMP" "$ARQUIVO_JSON"
chmod 644 "$ARQUIVO_JSON"

# Envia para o GitHub
cp "$ARQUIVO_JSON" "$REPO_DIR/monitor.json"
cp "$ARQUIVO_HISTORICO" "$REPO_DIR/monitor_historico.log"

cd "$REPO_DIR" || exit
git add monitor.json monitor_historico.log
git commit -m "Update: $HORA_ATUAL_STR" || true
git push origin main > /dev/null 2>&1
