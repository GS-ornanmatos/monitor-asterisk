const UPDATE_INTERVAL = 60000;
const URL_JSON = 'monitor.json';
const URL_LOG = 'monitor_historico.log';

let previousStatus = {};

function checkNotificationPermission() {
    if (!("Notification" in window)) {
        const btn = document.getElementById('btnNotif');
        if(btn) btn.style.display = 'none';
        return;
    }
    if (Notification.permission === "granted") {
        const btn = document.getElementById('btnNotif');
        if(btn) btn.style.display = 'none';
    }
}

function requestNotificationPermission() {
    if (!("Notification" in window)) {
        alert("Navegador sem suporte a notificações.");
        return;
    }
    Notification.requestPermission().then(permission => {
        if (permission === "granted") {
            new Notification("Monitoramento Ativado!", {body: "Você será avisado se um ramal cair."});
            checkNotificationPermission();
        }
    });
}

function sendNotification(ramal) {
    if (Notification.permission === "granted") {
        new Notification(`⚠️ ALERTA: Ramal ${ramal}`, {
            body: `O ramal ${ramal} ficou INDISPONÍVEL!`,
            requireInteraction: true,
            icon: "https://cdn-icons-png.flaticon.com/512/564/564619.png"
        });
    }
}

function renderGrid(data) {
    const grid = document.getElementById('gridRamais');
    grid.innerHTML = '';

    if (data.length === 0) {
        grid.innerHTML = '<div class="col-12 text-center text-muted">Nenhum ramal monitorado.</div>';
        return;
    }

    data.forEach(item => {
        // Verifica mudança de status para notificação
        if (previousStatus[item.ramal] &&
            previousStatus[item.ramal] !== 'Indisponivel' &&
            item.status === 'Indisponivel') {
            sendNotification(`${item.nome} (${item.ramal})`);
        }
        previousStatus[item.ramal] = item.status;

        let cardClass = '';
        let badgeClass = '';
        let statusIcon = '';

        switch (item.status) {
            case 'Indisponivel':
                cardClass = 'offline-blink';
                badgeClass = 'bg-danger';
                statusIcon = '🔴';
                break;
            case 'Ocupado':
                badgeClass = 'bg-warning text-dark';
                statusIcon = '📞';
                break;
            case 'Disponivel':
                badgeClass = 'bg-success';
                statusIcon = '🟢';
                break;
            case 'OFF!':
                badgeClass = 'bg-secondary';
                cardClass = 'opacity-75';
                statusIcon = '';
                break;
            default:
                badgeClass = 'bg-secondary';
        }

        const html = `
        <div class="col-xl-3 col-lg-4 col-md-6">
            <div class="card shadow-sm card-ramal ${cardClass}">
                <div class="card-body p-3 text-center">
                    <h5 class="card-title fw-bold mb-1 text-truncate" title="${item.nome}">${item.nome}</h5>
                    <span class="badge bg-light text-dark border mb-3">${item.ramal}</span>
                    
                    <span class="badge ${badgeClass} w-100 py-3 fs-6">${statusIcon} ${item.status}</span>
                </div>
            </div>
        </div>
        `;
        grid.innerHTML += html;
    });
}

async function fetchData() {
    const timestamp = new Date().getTime();
    const statusDot = document.getElementById('systemStatus');
    const statusText = document.getElementById('statusText');

    try {
        // Busca JSON
        const response = await fetch(`${URL_JSON}?t=${timestamp}`);
        if (!response.ok) throw new Error(`Erro HTTP: ${response.status}`);

        const data = await response.json();
        
        // Ordena por ramal
        data.sort((a, b) => parseInt(a.ramal) - parseInt(b.ramal));

        renderGrid(data);

        statusDot.className = "status-dot status-online";
        statusText.innerText = "Online e Sincronizado";
        document.getElementById('lastUpdate').innerText = new Date().toLocaleTimeString();

    } catch (error) {
        console.error("Falha ao buscar dados:", error);
        if(statusDot) statusDot.className = "status-dot status-error";
        if(statusText) statusText.innerText = "Falha ao ler monitor.json";
    }

    // Busca Logs (independente do sucesso do JSON)
    fetchLogs(timestamp);
}

async function fetchLogs(timestamp) {
    const logViewer = document.getElementById('logViewer');
    try {
        const response = await fetch(`${URL_LOG}?t=${timestamp}`);
        if (!response.ok) {
            logViewer.innerHTML = '<span class="text-muted">Arquivo de log vazio ou não encontrado.</span>';
            return;
        }
        const text = await response.text();
        const formattedHTML = text.split('\n').map(line => {
            if (!line.trim()) return '';
            if (line.includes('FALHA') || line.includes('ERRO')) return `<span class="log-error">${line}</span>`;
            if (line.includes('WARN')) return `<span class="log-warn">${line}</span>`;
            return `<span class="log-info">${line}</span>`;
        }).join('<br>');

        logViewer.innerHTML = formattedHTML || '<span class="text-muted">Sem registros recentes.</span>';
        logViewer.scrollTop = logViewer.scrollHeight;
    } catch (e) {
        console.log("Log error:", e);
    }
}

// Inicialização
document.addEventListener('DOMContentLoaded', () => {
    checkNotificationPermission();
    fetchData();
    setInterval(fetchData, UPDATE_INTERVAL);
});