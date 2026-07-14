/* LocalDrop browser client — vanilla JS, no frameworks. */
(function () {
  "use strict";

  const els = {
    body: document.body,
    pinForm: document.getElementById("pin-form"),
    pinInput: document.getElementById("pin-input"),
    pinError: document.getElementById("pin-error"),
    viewApp: document.getElementById("view-app"),
    viewPin: document.getElementById("view-pin"),
    tabs: Array.from(document.querySelectorAll(".tab")),
    tabFiles: document.getElementById("tab-files"),
    tabUpload: document.getElementById("tab-upload"),
    fileList: document.getElementById("file-list"),
    filesEmpty: document.getElementById("files-empty"),
    selectAll: document.getElementById("select-all"),
    downloadZip: document.getElementById("download-zip"),
    refresh: document.getElementById("refresh"),
    dropzone: document.getElementById("dropzone"),
    pickFiles: document.getElementById("pick-files"),
    fileInput: document.getElementById("file-input"),
    uploadList: document.getElementById("upload-list"),
    conn: document.getElementById("conn-status"),
    toast: document.getElementById("toast"),
  };

  const state = {
    token: null,
    files: [],
    selected: new Set(),
    uploads: new Map(),
  };

  /* ---------- helpers ---------- */
  function authHeaders() {
    const h = { "X-Requested-With": "fetch" };
    if (state.token) h["Authorization"] = "Bearer " + state.token;
    return h;
  }

  async function api(path, options) {
    options = options || {};
    options.credentials = "same-origin";
    options.headers = Object.assign(authHeaders(), options.headers || {});
    const res = await fetch(path, options);
    if (res.status === 401) {
      // Session expired
      logout();
      throw new Error("unauthorized");
    }
    if (!res.ok) throw new Error("http_" + res.status);
    return res;
  }

  function showToast(msg, ms) {
    els.toast.textContent = msg;
    els.toast.hidden = false;
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => (els.toast.hidden = true), ms || 2600);
  }

  function setConn(ok) {
    els.conn.classList.toggle("ok", ok === true);
    els.conn.classList.toggle("bad", ok === false);
  }

  function fmtSize(bytes) {
    if (bytes == null) return "";
    const u = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + " " + u[i];
  }

  function fmtDate(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    return d.toLocaleDateString() + " " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function iconFor(name) {
    const ext = (name.split(".").pop() || "").toLowerCase();
    const map = {
      png: "🖼", jpg: "🖼", jpeg: "🖼", gif: "🖼", webp: "🖼", svg: "🖼", heic: "🖼",
      mp4: "🎞", mov: "🎞", mkv: "🎞", webm: "🎞", avi: "🎞",
      mp3: "🎵", wav: "🎵", ogg: "🎵", flac: "🎵", m4a: "🎵",
      pdf: "📄", doc: "📝", docx: "📝", txt: "📝", md: "📝", rtf: "📝",
      xls: "📊", xlsx: "📊", csv: "📊",
      zip: "🗜", rar: "🗜", "7z": "🗜", gz: "🗜", tar: "🗜",
      apk: "📦", exe: "⚙",
    };
    if (map[ext]) return map[ext];
    if (["folder", "dir"].includes(ext)) return "📁";
    return "📄";
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }

  function uuid() {
    return (crypto.randomUUID && crypto.randomUUID()) ||
      (Date.now().toString(36) + Math.random().toString(36).slice(2));
  }

  /* ---------- auth ---------- */
  els.pinForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const pin = els.pinInput.value.trim();
    if (pin.length !== 6) return;
    try {
      const res = await fetch("/api/auth", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pin }),
      });
      if (!res.ok) {
        els.pinError.hidden = false;
        els.pinInput.value = "";
        return;
      }
      const data = await res.json();
      state.token = data.token;
      enterApp();
    } catch (err) {
      els.pinError.hidden = false;
      els.pinError.textContent = "Connection failed. Is the phone still on the network?";
    }
  });

  els.pinInput.addEventListener("input", () => {
    els.pinInput.value = els.pinInput.value.replace(/\D/g, "").slice(0, 6);
    els.pinError.hidden = true;
    if (els.pinInput.value.length === 6) els.pinForm.requestSubmit();
  });

  function logout() {
    state.token = null;
    els.viewApp.hidden = true;
    els.viewPin.hidden = false;
    els.body.dataset.view = "pin";
  }

  async function enterApp() {
    els.viewPin.hidden = true;
    els.viewApp.hidden = false;
    els.body.dataset.view = "app";
    await loadFiles();
  }

  /* ---------- files ---------- */
  async function loadFiles() {
    try {
      const res = await api("/api/files");
      const data = await res.json();
      state.files = data.files || [];
      state.selected.clear();
      renderFiles();
      setConn(true);
    } catch (err) {
      if (err.message !== "unauthorized") {
        setConn(false);
        showToast("Could not reach the phone.");
      }
    }
  }

  function renderFiles() {
    els.fileList.innerHTML = "";
    els.filesEmpty.hidden = state.files.length > 0;
    for (const f of state.files) {
      const row = document.createElement("div");
      row.className = "file-row";
      row.dataset.name = f.name;
      const checked = state.selected.has(f.name);
      if (checked) row.classList.add("selected");
      row.innerHTML = `
        <input type="checkbox" class="file-check" ${checked ? "checked" : ""} />
        <div class="file-icon">${iconFor(f.name)}</div>
        <div class="file-meta">
          <div class="file-name">${escapeHtml(f.name)}</div>
          <div class="file-sub">${fmtSize(f.size)} · ${fmtDate(f.modified)}</div>
        </div>
        <div class="file-actions">
          <button class="btn primary dl" title="Download">↓ Download</button>
        </div>`;
      row.querySelector(".file-check").addEventListener("change", (e) => {
        if (e.target.checked) state.selected.add(f.name);
        else state.selected.delete(f.name);
        row.classList.toggle("selected", e.target.checked);
        updateSelectionUI();
      });
      row.querySelector(".dl").addEventListener("click", () => downloadFile(f.name));
      els.fileList.appendChild(row);
    }
    updateSelectionUI();
  }

  function updateSelectionUI() {
    els.downloadZip.disabled = state.selected.size === 0;
    els.selectAll.checked = state.files.length > 0 && state.selected.size === state.files.length;
  }

  els.selectAll.addEventListener("change", (e) => {
    if (e.target.checked) state.files.forEach((f) => state.selected.add(f.name));
    else state.selected.clear();
    renderFiles();
  });

  els.refresh.addEventListener("click", loadFiles);

  els.downloadZip.addEventListener("click", () => {
    const names = Array.from(state.selected);
    if (!names.length) return;
    const q = encodeURIComponent(names.join(","));
    const a = document.createElement("a");
    a.href = "/api/download-zip?files=" + q;
    a.download = "localdrop.zip";
    document.body.appendChild(a);
    a.click();
    a.remove();
  });

  function downloadFile(name) {
    const a = document.createElement("a");
    a.href = "/api/download/" + encodeURIComponent(name);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  /* ---------- tabs ---------- */
  els.tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      els.tabs.forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");
      const name = tab.dataset.tab;
      els.tabFiles.hidden = name !== "files";
      els.tabUpload.hidden = name !== "upload";
    });
  });

  /* ---------- upload (XHR gives reliable progress) ---------- */
  els.pickFiles.addEventListener("click", () => els.fileInput.click());
  els.fileInput.addEventListener("change", (e) => {
    handleFiles(e.target.files);
    els.fileInput.value = "";
  });

  ["dragenter", "dragover"].forEach((ev) =>
    els.dropzone.addEventListener(ev, (e) => {
      e.preventDefault();
      els.dropzone.classList.add("over");
    })
  );
  ["dragleave", "drop"].forEach((ev) =>
    els.dropzone.addEventListener(ev, (e) => {
      e.preventDefault();
      els.dropzone.classList.remove("over");
    })
  );
  els.dropzone.addEventListener("drop", (e) => {
    if (e.dataTransfer && e.dataTransfer.files) handleFiles(e.dataTransfer.files);
  });

  function handleFiles(fileList) {
    for (const file of Array.from(fileList)) startUpload(file);
  }

  function startUpload(file) {
    const id = uuid();
    const fd = new FormData();
    fd.append("file", file, file.name);

    const row = document.createElement("div");
    row.className = "up-row";
    row.innerHTML = `
      <div class="up-head">
        <span class="up-name">${escapeHtml(file.name)}</span>
        <span class="up-sub">0%</span>
      </div>
      <div class="progress"><span></span></div>
      <div class="up-sub" style="margin-top:.35rem">0 / ${fmtSize(file.size)} · preparing…</div>`;
    els.uploadList.prepend(row);
    const bar = row.querySelector(".progress > span");
    const pct = row.querySelector(".up-sub:last-child");
    const subHead = row.querySelector(".up-sub:first-of-type");

    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/api/upload?id=" + id);
    xhr.setRequestHeader("X-Requested-With", "fetch");
    if (state.token) xhr.setRequestHeader("Authorization", "Bearer " + state.token);
    xhr.withCredentials = true;

    xhr.upload.onprogress = (e) => {
      const p = e.total ? (e.loaded / e.total) * 100 : 0;
      bar.style.width = p.toFixed(1) + "%";
      subHead.textContent = p.toFixed(0) + "%";
      pct.textContent = fmtSize(e.loaded) + " / " + fmtSize(e.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        bar.style.width = "100%";
        subHead.textContent = "Done";
        pct.textContent = fmtSize(file.size) + " · uploaded";
        loadFiles();
      } else if (xhr.status === 401) {
        logout();
      } else {
        subHead.textContent = "Failed";
        pct.textContent = "Upload error (" + xhr.status + ")";
      }
    };
    xhr.onerror = () => {
      subHead.textContent = "Failed";
      pct.textContent = "Connection lost";
      setConn(false);
    };
    xhr.send(fd);
  }

  /* ---------- periodic heartbeat ---------- */
  setInterval(() => {
    if (els.body.dataset.view === "app") loadFiles();
  }, 8000);

  /* ---------- boot ---------- */
  els.pinInput.focus();
})();
