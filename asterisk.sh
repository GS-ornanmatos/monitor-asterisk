#!/bin/bash

set -u

# --- 1. CONFIGURAÇÃO DE RAMAIS (EDITAR AQUI) ---
# Formato: ["NUMERO"]="NOME_DO_USUARIO|INICIO_TURNO|FIM_TURNO"
# Horario em formato HHMM (Ex: 0800 para 8h da manha, 1800 para 18h)
declare -A CONFIG
CONFIG["388"]="Gabriel Paixão|0705|1600"
CONFIG["375"]="Ian Silva|0705|1600"
CONFIG["387"]="Raiane Mendes|1330|2130"
CONFIG["383"]="Lorrana Silva|1330|2130"
CONFIG["382"]="Lucas Yuri|1330|2130"
CONFIG["373"]="Wilson|1330|2130"


# --- CONSTANTES ---
ASTERISK_BIN="/usr/sbin/asterisk"
DATE_BIN="/bin/date"
AWK_BIN="/usr/bin/awk"
FLOCK_BIN="/usr/bin/flock"

# --- CAMINHOS ---
DIR_OUTPUT="/var/www/html" # Ou onde você salva o json localmente
ARQUIVO_JSON="$DIR_OUTPUT/monitor.json"
ARQUIVO_JSON_TMP="$DIR_OUTPUT/monitor.json.tmp"
ARQUIVO_HISTORICO="/var/log/asterisk/monitor_historico.log"
CDR_MASTER="/var/log/asterisk/cdr-csv/Master.csv"
LOCK_FILE="/tmp/monitor_asterisk.lock"
REPO_DIR="/opt/monitor-asterisk" # Pasta do Git

# --- LOCK & DATA ---
exec 200>"$LOCK_FILE"
if ! $FLOCK_BIN -n 200; then exit 0; fi

DATA_HOJE=$($DATE_BIN +%Y-%m-%d)
HORA_ATUAL_STR=$($DATE_BIN '+%H:%M')
HORA_ATUAL_NUM=$($DATE_BIN '+%H%M') # Ex: 1430
DATA_COMPLETA=$($DATE_BIN '+%F %T')

# --- 2. MAPA DE CHAMADAS ---
declare -A MAP_RX
declare -A MAP_TX

if [ -f "$CDR_MASTER" ]; then

    while read -r RAMAL TIPO QTD; do
        if [ "$TIPO" == "RX" ]; then MAP_RX["$RAMAL"]=$QTD; fi
        if [ "$TIPO" == "TX" ]; then MAP_TX["$RAMAL"]=$QTD; fi
    done < <($AWK_BIN -v d="$DATA_HOJE" -F',' '
        index($0, d) && index($0, "ANSWERED") {
            # --- CHAMADAS RECEBIDAS (Onde o ramal é o destino/dstchannel) ---
            # Procura PJSIP/RAMAL em qualquer lugar da linha (geralmente col 6 ou 7)
            for(i=1;i<=NF;i++) {
                if($i ~ /PJSIP\//) {
                    split($i, a, "/"); split(a[2], b, "-"); gsub(/"/, "", b[1]);
                    rx_count[b[1]]++;
                }
            }
            # --- CHAMADAS FEITAS (Onde o ramal é a origem/src - Coluna 2) ---
            src = $2; gsub(/"/, "", src);
            if (src ~ /^[0-9]+$/) { # Se a origem for numero (ramal)
                 tx_count[src]++;
            }
        }
        END { 
            for (r in rx_count) print r, "RX", rx_count[r]
            for (r in tx_count) print r, "TX", tx_count[r]
        }
    ' "$CDR_MASTER")
fi

# --- 3. LOOP PRINCIPAL ---
printf "[\n" > "$ARQUIVO_JSON_TMP"
FIRST=1

# Itera somente sobre os ramais definidos na CONFIG
for RAMAL in "${!CONFIG[@]}"; do
    

    IFS='|' read -r NOME INICIO FIM <<< "${CONFIG[$RAMAL]}"
    

    if [[ "$HORA_ATUAL_NUM" -lt "$INICIO" ]] || [[ "$HORA_ATUAL_NUM" -gt "$FIM" ]]; then
        STATUS="Fora de Horario"
        COR="secondary" # Cinza
    else

        STATUS_RAW=$($ASTERISK_BIN -rx "pjsip show endpoint $RAMAL" 2>/dev/null | grep "Device State" | $AWK_BIN '{print $3}') 
        
        $AWK_BIN '{print $3}')
        
        if [[ "$STATUS_RAW" == *"Busy"* ]] || [[ "$STATUS_RAW" == *"In use"* ]]; then
            STATUS="Ocupado"; COR="warning"
        elif [[ "$STATUS_RAW" == *"Not in use"* ]] || [[ "$STATUS_RAW" == *"Avail"* ]]; then
            STATUS="Disponivel"; COR="success"
        else
            STATUS="Indisponivel"; COR="danger"

            echo "$DATA_COMPLETA | RAMAL $RAMAL ($NOME) | FALHA | Status: Indisponivel" >> "$ARQUIVO_HISTORICO"
        fi
    fi


    QTD_RX=${MAP_RX["$RAMAL"]:-0}
    QTD_TX=${MAP_TX["$RAMAL"]:-0}

    # Gera JSON
    if [ "$FIRST" -eq 0 ]; then printf ",\n" >> "$ARQUIVO_JSON_TMP"; fi
    FIRST=0

    printf "  {\n    \"ramal\": \"%s\",\n    \"nome\": \"%s\",\n    \"status\": \"%s\",\n    \"cor\": \"%s\",\n    \"rx\": \"%s\",\n    \"tx\": \"%s\",\n    \"atualizado\": \"%s\"\n  }" \
      "$RAMAL" "$NOME" "$STATUS" "$COR" "$QTD_RX" "$QTD_TX" "$HORA_ATUAL_STR" >> "$ARQUIVO_JSON_TMP"

done

printf "\n]\n" >> "$ARQUIVO_JSON_TMP"

# --- 4. FINALIZAÇÃO E GITHUB ---
mv "$ARQUIVO_JSON_TMP" "$ARQUIVO_JSON"
chmod 644 "$ARQUIVO_JSON"

# Copia para o Git
cp "$ARQUIVO_JSON" "$REPO_DIR/monitor.json"
cp "$ARQUIVO_HISTORICO" "$REPO_DIR/monitor_historico.log"

# Envia
cd "$REPO_DIR" || exit
git add monitor.json monitor_historico.log
git commit -m "Update: $HORA_ATUAL_STR" || true
git push origin main > /dev/null 2>&1