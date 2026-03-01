const state = {
  token: null,
  user: null,
  isAdmin: false,
  currentPage: 0,
  totalPages: 0,
  apiLogs: [],
  selectedGameId: null,
  bsModal: null
};

const $ = (id) => document.getElementById(id);
const $all = (selector) => document.querySelectorAll(selector);

function parseJwt(token) {
  try {
    const base64Url = token.split('.')[1];
    const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
    const jsonPayload = decodeURIComponent(atob(base64).split('').map(c => {
      return '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2);
    }).join(''));
    return JSON.parse(jsonPayload);
  } catch (e) {
    return null;
  }
}

function log(method, url, status, type = 'info') {
  const time = new Date().toLocaleTimeString();
  const line = document.createElement('div');
  line.className = 'mb-1 small';

  const colorClass = type === 'success' ? 'text-success' : (type === 'error' ? 'text-danger' : 'text-info');
  const statusText = status ? ` <span class="badge bg-secondary ms-1">${status}</span>` : '';

  line.innerHTML = `
        <span class="text-secondary opacity-50 font-monospace" style="font-size: 0.7rem">${time}</span> 
        <strong class="${colorClass}">${method}</strong> 
        <span class="text-secondary">${url}</span>${statusText}
    `;

  const dashboardLogs = $('dashboardLogs');
  const fullLogs = $('fullLogs');

  if (dashboardLogs) {
    const dashClone = line.cloneNode(true);
    dashboardLogs.prepend(dashClone);
    if (dashboardLogs.children.length > 20) dashboardLogs.lastChild.remove();
  }

  if (fullLogs) {
    fullLogs.appendChild(line);
    fullLogs.scrollTop = fullLogs.scrollHeight;
  }
}

async function nexusFetch(path, options = {}) {
  const baseUrl = $('apiBase').value.replace(/\/$/, '');
  const url = `${baseUrl}${path}`;
  const startTime = performance.now();

  const headers = {
    'Content-Type': 'application/json',
    ...options.headers
  };

  if (state.token) {
    headers['Authorization'] = `Bearer ${state.token}`;
  }

  try {
    const response = await fetch(url, { ...options, headers });
    const endTime = performance.now();
    const latency = Math.round(endTime - startTime);
    if ($('avgLatency')) $('avgLatency').textContent = `${latency}ms`;

    let type = response.ok ? 'success' : 'error';
    log(options.method || 'GET', path, response.status, type);

    if (response.status === 401) {
      if (state.token) logout();
    }

    if (response.status === 204) return null;

    const data = await response.json();
    return data;
  } catch (error) {
    log(options.method || 'GET', path, 'FAILED', 'error');
    throw error;
  }
}

async function doLogin() {
  const email = $('loginEmail').value;
  const password = $('loginPass').value;
  const errorEl = $('loginError');

  errorEl.style.display = 'none';
  $('btnLogin').disabled = true;
  $('btnLogin').innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>Conectando...';

  try {
    const data = await nexusFetch('/api/v1/auth/signin', {
      method: 'POST',
      body: JSON.stringify({ email, password })
    });

    const token = data.token || data.jwt;
    if (token) {
      state.token = token;
      const claims = parseJwt(token);
      state.user = claims;

      const roles = claims.roles || claims.authorities || [];
      const roleStrings = roles.map(r => typeof r === 'string' ? r : (r.authority || ''));
      state.isAdmin = roleStrings.includes('ROLE_ADMIN');

      setupUI();
      $('viewLogin').style.display = 'none';
      $('appContainer').style.display = 'block';

      loadDashboard();
    } else {
      throw new Error("Token no recibido");
    }
  } catch (err) {
    errorEl.textContent = "Error: Verifica las credenciales o el estado de la API.";
    errorEl.style.display = 'block';
  } finally {
    $('btnLogin').disabled = false;
    $('btnLogin').textContent = 'Ingresar al Nexo';
  }
}

function logout() {
  state.token = null;
  state.user = null;
  state.isAdmin = false;
  $('viewLogin').style.display = 'flex';
  $('appContainer').style.display = 'none';
}

function setupUI() {
  $('displayEmail').textContent = state.user.sub || state.user.email;
  $('displayRole').textContent = state.isAdmin ? 'Administrador' : 'Usuario';

  if (state.isAdmin) {
    $('navUsers').style.display = 'block';
    $('btnShowAddGame').style.display = 'inline-block';
    $('thActions').style.display = 'table-cell';
  } else {
    $('navUsers').style.display = 'none';
    $('btnShowAddGame').style.display = 'none';
    $('thActions').style.display = 'none';
  }
}

function switchTo(view) {
  $all('.view-section').forEach(s => s.classList.remove('active'));
  $all('.nav-link').forEach(i => i.classList.remove('active'));

  const targetView = $(`view${view.charAt(0).toUpperCase() + view.slice(1)}`);
  if (targetView) targetView.classList.add('active');

  $all('.nav-link').forEach(i => {
    if (i.dataset.target === view) i.classList.add('active');
  });

  if (view === 'games') loadGames();
  if (view === 'users' && state.isAdmin) loadUsers();
  if (view === 'dashboard') loadDashboard();
}

async function loadDashboard() {
  try {
    const gamesData = await nexusFetch('/api/v1/videojuegos?size=1');
    $('countGames').textContent = gamesData.totalElements || 0;

    let onlineCount = 0;
    if (gamesData.totalElements > 0) {
      const sample = await nexusFetch(`/api/v1/videojuegos?size=100`);
      onlineCount = (sample.content || []).filter(g => g.esOnline).length;
    }
    $('countOnline').textContent = onlineCount;

    if (state.isAdmin) {
      const users = await nexusFetch('/api/v1/users');
      $('countUsers').textContent = users.length || 0;
    } else {
      $('countUsers').textContent = '--';
    }
  } catch (e) {
    console.error("Dashboard error", e);
  }
}

async function loadGames(page = 0) {
  state.currentPage = page;
  try {
    const data = await nexusFetch(`/api/v1/videojuegos?page=${page}&size=10`);
    const tbody = $('gamesBody');
    tbody.innerHTML = '';

    (data.content || []).forEach(game => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
                <td class="ps-4 text-secondary small">${game.id}</td>
                <td><strong>${game.nombre}</strong></td>
                <td>${game.desarrollador}</td>
                <td>
                    <span class="status-badge bg-${game.esOnline ? 'success' : 'secondary'}-subtle text-${game.esOnline ? 'success' : 'secondary'}">
                        ${game.esOnline ? 'Online' : 'Un Jugador'}
                    </span>
                </td>
                ${state.isAdmin ? `
                <td class="text-end pe-4">
                    <button class="btn btn-sm btn-link text-info me-2 p-0" onclick="editGame(${game.id})">Editar</button>
                    <button class="btn btn-sm btn-link text-danger p-0" onclick="deleteGame(${game.id})">Borrar</button>
                </td>
                ` : ''}
            `;
      tbody.appendChild(tr);
    });

    state.totalPages = data.totalPages;
    $('pageLabel').textContent = `Página ${page + 1} de ${data.totalPages || 1}`;
    $('prevPage').disabled = page === 0;
    $('nextPage').disabled = page >= (data.totalPages - 1);

  } catch (e) {
    console.error("Games error", e);
  }
}

function changePage(dir) {
  if (dir === 1 && state.currentPage < state.totalPages - 1) loadGames(state.currentPage + 1);
  if (dir === -1 && state.currentPage > 0) loadGames(state.currentPage - 1);
}

function openGameModal(game = null) {
  if (game) {
    $('modalTitle').textContent = 'Edición de Título';
    $('gameId').value = game.id;
    $('gameName').value = game.nombre;
    $('gameDev').value = game.desarrollador;
    $('gameOnline').checked = game.esOnline;
    state.selectedGameId = game.id;
  } else {
    $('modalTitle').textContent = 'Añadir nuevo Videojuego';
    $('gameId').value = '';
    $('gameName').value = '';
    $('gameDev').value = '';
    $('gameOnline').checked = false;
    state.selectedGameId = null;
  }

  if (!state.bsModal) {
    state.bsModal = new bootstrap.Modal($('gameModal'));
  }
  state.bsModal.show();
}

function closeGameModal() {
  if (state.bsModal) state.bsModal.hide();
}

async function saveGame() {
  const gameData = {
    nombre: $('gameName').value,
    desarrollador: $('gameDev').value,
    esOnline: $('gameOnline').checked
  };

  const method = state.selectedGameId ? 'PUT' : 'POST';
  const path = state.selectedGameId ? `/api/v1/videojuegos/${state.selectedGameId}` : '/api/v1/videojuegos';

  try {
    await nexusFetch(path, {
      method,
      body: JSON.stringify(gameData)
    });
    closeGameModal();
    loadGames(state.currentPage);
    loadDashboard();
  } catch (e) {
    alert("Error al procesar la solicitud.");
  }
}

async function editGame(id) {
  try {
    const game = await nexusFetch(`/api/v1/videojuegos/${id}`);
    openGameModal(game);
  } catch (e) {
    alert("No se pudieron cargar los detalles.");
  }
}

async function deleteGame(id) {
  if (!confirm("¿Eliminar este videojuego permanentemente?")) return;
  try {
    await nexusFetch(`/api/v1/videojuegos/${id}`, { method: 'DELETE' });
    loadGames(state.currentPage);
    loadDashboard();
  } catch (e) {
    alert("Error al eliminar.");
  }
}

async function loadUsers() {
  try {
    const users = await nexusFetch('/api/v1/users');
    const tbody = $('usersBody');
    tbody.innerHTML = '';

    users.forEach(user => {
      const tr = document.createElement('tr');
      tr.innerHTML = `
                <td class="ps-4 text-secondary small">${user.id}</td>
                <td class="fw-bold">${user.firstName} ${user.lastName}</td>
                <td class="text-secondary">${user.email}</td>
                <td class="pe-4">${(user.roles || []).map(r => `<span class="badge bg-secondary-subtle text-secondary me-1 font-monospace">${r}</span>`).join('')}</td>
            `;
      tbody.appendChild(tr);
    });
  } catch (e) {
    console.error("Users error", e);
  }
}

function useDemo(role) {
  if (role === 'user') {
    $('loginEmail').value = 'alice.johnson@example.com';
    $('loginPass').value = 'password123';
  } else {
    $('loginEmail').value = 'bob.smith@example.com';
    $('loginPass').value = 'password456';
  }
}

document.addEventListener('DOMContentLoaded', () => {
  $('btnLogin').onclick = doLogin;

  $('loginPass').addEventListener('keypress', (e) => {
    if (e.key === 'Enter') doLogin();
  });
});
