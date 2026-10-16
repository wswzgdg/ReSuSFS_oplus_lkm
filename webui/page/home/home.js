import { exec } from 'kernelsu-alt';
import { basePath, moduleDirectory, filePaths, runReSuSFS, updateUIVisibility, linkRedirect, showPrompt } from '../../utils/util.js';
import { getString } from '../../utils/language.js';
import { addCopyToClipboardListeners } from '../../utils/docs.js';
import { exportConfig, restoreConfig } from '../../utils/backup.js';

/**
 * Config files shown as tiles in the summary box, in display order.
 * `key` maps to filePaths / util.js, `label` is an i18n string key.
 */
const SUMMARY_FILES = [
    { key: 'sus_paths', label: 'susfs_sus_paths_title' },
    { key: 'sus_paths_loop', label: 'susfs_sus_paths_loop_title' },
    { key: 'sus_maps', label: 'susfs_sus_maps_title' },
    { key: 'kstat_paths', label: 'susfs_kstat_paths_title' },
    { key: 'open_redirect', label: 'susfs_open_redirect_title' },
];
const SCRIPTS_POSTFS = 'scripts_postfs.txt';
const SCRIPTS_BOOTCOMPLETED = 'scripts_bootcompleted.txt';

/**
 * Count non-comment, non-blank lines in a config file.
 * @param {string} fileName
 * @returns {Promise<number>}
 */
async function countEntries(fileName) {
    const result = await exec(`sed 's/#.*//' "${basePath}/${fileName}" 2>/dev/null | grep -c '[^[:space:]]'`);
    if (result.errno !== 0) return 0;
    const n = parseInt(result.stdout.trim(), 10);
    return Number.isFinite(n) ? n : 0;
}

async function countEnabledScripts() {
    const command = `
        cat "${basePath}/${SCRIPTS_POSTFS}" "${basePath}/${SCRIPTS_BOOTCOMPLETED}" 2>/dev/null \
        | sed 's/#.*//' | grep -v '^[[:space:]]*$' | grep -v '^!' | sort -u | wc -l
    `;
    const result = await exec(command);
    if (result.errno !== 0) return 0;
    const n = parseInt(result.stdout.trim(), 10);
    return Number.isFinite(n) ? n : 0;
}

async function updateSummary() {
    const grid = document.getElementById('summary-grid');
    if (!grid) return;
    grid.innerHTML = '';

    const [counts, scriptCount] = await Promise.all([
        Promise.all(SUMMARY_FILES.map(({ key }) => countEntries(filePaths[key]))),
        countEnabledScripts(),
    ]);
    const tiles = SUMMARY_FILES.map(({ label }, index) => ({
        count: counts[index],
        label: getString(label),
        page: 'susfs',
    }));
    tiles.push({
        count: scriptCount,
        label: getString('summary_enabled_scripts'),
        page: 'userhub',
    });

    for (const { count, label, page } of tiles) {
        const tile = document.createElement('div');
        tile.className = 'summary-tile';
        tile.innerHTML = `
            <span class="summary-tile-count">${count}</span>
            <span class="summary-tile-label">${label}</span>
        `;
        tile.onclick = () => document.querySelector(`.bottom-bar-item[page="${page}"]`)?.click();
        grid.appendChild(tile);
    }
}

async function getLkmInterfaces() {
    const result = await exec('for node in /proc/susfs_*; do [ -e "$node" ] && printf "%s\n" "${node##*/}"; done');
    return result.stdout.trim().split(/\s+/).filter(Boolean);
}

async function updateLkmStatus() {
    const result = await exec(`brand=$(getprop ro.product.brand | tr '[:upper:]' '[:lower:]'); maker=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]'); case "\$brand \$maker" in *oppo*|*oneplus*|*realme*) family=1 ;; *) family=0 ;; esac; enabled=$(cat /data/adb/ReSuSFS/lkm_enabled 2>/dev/null); loaded=$([ -d /sys/module/susfs_guard_lkm ] && echo 1 || echo 0); installed=$([ -s /data/adb/loader/susfs_guard_lkm.ko ] && echo 1 || echo 0); printf '%s %s %s %s' "\$family" "\${enabled:-0}" "\$loaded" "\$installed"`);
    const [family = '0', enabled = '0', loaded = '0', installed = '0'] = result.stdout.trim().split(/\s+/);
    const nodes = loaded === '1' ? await getLkmInterfaces() : [];
    const cli = await exec('[ -x /data/adb/ksu/bin/ksu_susfs ]');
    const card = document.getElementById('lkm-control-card');
    if (!card) return;
    card.style.display = family === '1' ? '' : 'none';
    const status = document.getElementById('lkm-status-text');
    const toggle = document.getElementById('lkm-toggle-btn');
    if (!status || !toggle) return;
    const loadState = loaded === '1' ? getString('lkm_loaded') : installed === '1' ? getString('lkm_installed') : getString('lkm_missing');
    const startupState = enabled === '1' ? getString('lkm_enabled') : getString('lkm_disabled');
    status.textContent = getString('lkm_state', loadState, startupState);
    const capabilities = document.getElementById('lkm-capabilities');
    if (capabilities) {
        const detected = nodes.length ? nodes.join(', ') : getString('lkm_no_interfaces');
        const cliState = cli.errno === 0 ? getString('lkm_cli_available') : getString('lkm_cli_missing');
        capabilities.textContent = `${getString('lkm_interfaces', detected)}; ${cliState}`;
    }
    toggle.disabled = installed !== '1' && enabled !== '1';
    toggle.textContent = getString(enabled === '1' ? 'lkm_disable' : 'lkm_enable');
}

async function runLkmCommand(command) {
    const succeeded = await runReSuSFS(command);
    showPrompt(succeeded ? getString('lkm_command_success') : getString('lkm_command_failed'), succeeded);
    await updateLkmStatus();
}

async function updateStatus() {
    const statusText = document.getElementById('status-text');
    const statusDot = document.getElementById('status-dot');
    const kernelVersionEl = document.getElementById('status-kernel-version');
    const featureCountEl = document.getElementById('status-feature-count');

    const susfsBin = await getSusfsBin();
    const [binCheck, lkmCheck, versionResult, variantResult, featuresResult] = await Promise.all([
        exec(`[ -x "${susfsBin}" ]`),
        exec(`[ -d /sys/module/susfs_guard_lkm ]`),
        exec(`"${susfsBin}" show version 2>/dev/null`),
        exec(`"${susfsBin}" show variant 2>/dev/null`),
        exec(`"${susfsBin}" show enabled_features 2>/dev/null`),
    ]);

    const version = versionResult.errno === 0 ? versionResult.stdout.trim() : '';
    const variant = variantResult.errno === 0 ? variantResult.stdout.trim() : '';
    const lkmInterfaces = lkmCheck.errno === 0 ? await getLkmInterfaces() : [];
    const features = featuresResult.errno === 0
        ? featuresResult.stdout.split('\n').map(l => l.trim()).filter(Boolean)
        : [];

    document.getElementById('features-version').textContent = version || getString('status_unknown');
    document.getElementById('features-variant').textContent = variant || getString('status_unknown');
    const featuresList = document.getElementById('features-list');
    featuresList.innerHTML = '';
    if (features.length === 0) {
        featuresList.innerHTML = `<p class="features-empty">${getString('features_none')}</p>`;
    } else {
        features.forEach(feature => {
            const row = document.createElement('div');
            row.className = 'feature-row';
            row.innerHTML = `
                <md-icon class="feature-check">
                    <svg xmlns="http://www.w3.org/2000/svg" height="18px" viewBox="0 -960 960 960" width="18px"><path d="M382-240 154-468l57-57 171 171 367-367 57 57-424 424Z"/></svg>
                </md-icon>
                <span>${feature}</span>
            `;
            featuresList.appendChild(row);
        });
    }

    if (version) {
        statusDot.className = 'status-dot active';
        statusText.textContent = getString('status_active');
        kernelVersionEl.textContent = getString('status_kernel_version', version);
        featureCountEl.textContent = getString('status_feature_count', features.length);
        featureCountEl.style.display = 'inline';
    } else if (lkmCheck.errno === 0) {
        statusDot.className = 'status-dot active';
        statusText.textContent = getString('lkm_active_partial');
        kernelVersionEl.textContent = getString('lkm_interfaces', lkmInterfaces.join(', ') || getString('lkm_no_interfaces'));
        featureCountEl.style.display = 'none';
    } else {
        statusDot.className = 'status-dot inactive';
        kernelVersionEl.textContent = '';
        featureCountEl.style.display = 'none';
        const binExists = binCheck.errno === 0;
        statusText.textContent = binExists ? getString('status_unsupported_version') : getString('status_binary_missing');
    }
}

async function getSusfsBin() {
    const result = await exec(`grep '^SUSFS_BIN=' "${moduleDirectory}/ReSuSFS.sh" | head -n1 | cut -d= -f2`);
    const path = result.errno === 0 ? result.stdout.trim() : '';
    return path || '/data/adb/ksu/bin/ksu_susfs';
}

/**
 * Open the enabled-features dialog when the status box is tapped.
 * @returns {void}
 */
function setupStatusBox() {
    const statusBox = document.getElementById('status-box');
    statusBox.onclick = () => {
        document.getElementById('features-dialog')?.show();
    };

    // Handle close button
    const closeBtn = document.querySelector('#features-dialog .close-btn');
    if (closeBtn) {
        closeBtn.onclick = () => {
            document.getElementById('features-dialog')?.close();
        };
    }
}

function setupSupportCard() {
    const card = document.getElementById('support-card');
    const closeBtn = document.getElementById('support-card-close');
    if (!card) return;

    if (localStorage.getItem('resusfs_support_dismissed') === '1') {
        card.style.display = 'none';
        return;
    }

    if (card) card.onclick = () => linkRedirect('https://github.com/wswzgdg#-support-my-work');
    closeBtn.onclick = () => {
        card.style.display = 'none';
        localStorage.setItem('resusfs_support_dismissed', '1');
    };
}

function setupBackupCard() {
    const exportBtn = document.getElementById('home-export-btn');
    const restoreBtn = document.getElementById('home-restore-btn');
    if (exportBtn) exportBtn.onclick = () => exportConfig();
    if (restoreBtn) restoreBtn.onclick = () => restoreConfig();
}

function setupTelegramHint() {
    const hint = document.getElementById('telegram-hint');
    if (hint) hint.onclick = () => linkRedirect('https://t.me/ahmed_alnassif_tg');
}

export function mount() {
    setupStatusBox();
    setupSupportCard();
    document.getElementById('lkm-install-btn').onclick = () => runLkmCommand('--lkm-install');
    document.getElementById('lkm-toggle-btn').onclick = async () => {
        const result = await exec(`cat /data/adb/ReSuSFS/lkm_enabled 2>/dev/null`);
        await runLkmCommand(result.stdout.trim() === '1' ? '--lkm-disable' : '--lkm-enable');
    };
    setupBackupCard();
    setupTelegramHint();

    const actionBtn = document.getElementById('action-btn');
    const forceUpdateButton = document.getElementById('force-update-btn');
    actionBtn.onclick = () => runReSuSFS('--action');
    forceUpdateButton.onclick = () => runReSuSFS('--force-update');
}

export function onShow() {
    updateUIVisibility();
    updateStatus();
    updateLkmStatus();
    updateSummary();
}

export function onHide() {
    document.querySelectorAll('.fab-container').forEach(c => c.classList.remove('show', 'inTerminal'));
}
