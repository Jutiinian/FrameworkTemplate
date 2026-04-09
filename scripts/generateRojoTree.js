#!/usr/bin/env node
// generateRojoTree.js
// Generates default.project.json from src/ directory structure.
// Folder matching is case-insensitive throughout.

const fs = require("fs");
const path = require("path");

const BASE_PATH = path.join(__dirname, "../src");
const PROJECT_ROOT = path.join(__dirname, "..");

// Read project name from game.toml
// game.toml is the project-level config file. Minimal expected format:
//
//   name = "MyGame"
//
// Falls back to the directory name if game.toml is missing or has no name field.
function readProjectName() {
	const gamePath = path.join(PROJECT_ROOT, "game.toml");
	try {
		const contents = fs.readFileSync(gamePath, "utf8");
		const match = contents.match(/^\s*name\s*=\s*"([^"]+)"/m);
		if (match) return match[1];
		console.warn("⚠ No name field found in game.toml — using directory name");
	} catch {
		console.warn("⚠ game.toml not found — using directory name");
	}
	return path.basename(PROJECT_ROOT);
}

const PROJECT_NAME = readProjectName();

// ── Utility functions ─────────────────────────────────────────────────────────

function toPosix(p) {
	return p.split(path.sep).join("/");
}

function toPascalCase(str) {
	return str.charAt(0).toUpperCase() + str.slice(1);
}

// Convert an absolute filepath to a src/-relative Rojo path string
function toSrcPath(filepath) {
	return "src/" + toPosix(path.relative(BASE_PATH, filepath));
}

// Convert an absolute directory path to a src/-relative Rojo path string
function toSrcDir(dirpath) {
	return "src/" + toPosix(path.relative(BASE_PATH, dirpath));
}

function pathExists(p) {
	try {
		fs.accessSync(p);
		return true;
	} catch {
		return false;
	}
}

/**
 * Case-insensitive scan of a directory to find a child whose lowercase name
 * matches `lowerName`. Returns the actual on-disk name or null if not found.
 */
function findDir(basePath, lowerName) {
	if (!pathExists(basePath)) return null;
	try {
		const entry = fs
			.readdirSync(basePath, { withFileTypes: true })
			.find((e) => e.isDirectory() && e.name.toLowerCase() === lowerName);
		return entry ? entry.name : null;
	} catch {
		return null;
	}
}

// ── Discover top-level source directories (any casing) ───────────────────────
// Using findDir for all of these means BLACKLISTED_DIRS and static $path
// entries below always use the real on-disk name, so casing never matters.

const featuresDir = findDir(BASE_PATH, "features");
const servicesDir = findDir(BASE_PATH, "services");
const startupDir = findDir(BASE_PATH, "startup");
const sharedDir = findDir(BASE_PATH, "shared");
const uiDir = findDir(BASE_PATH, "ui");
const assetsDir = findDir(BASE_PATH, "assets");

const hasFeatures = featuresDir !== null;
const hasServices = servicesDir !== null;

// Directories managed via static $path entries — the walk skips them entirely.
// Built from actual on-disk names so a capitalised "Startup" or "Assets" folder
// is correctly excluded just like the lowercase variant.
const BLACKLISTED_DIRS = [startupDir, sharedDir, uiDir, assetsDir].reduce((acc, name) => {
	if (name) acc.push(toPosix(path.join(BASE_PATH, name)));
	return acc;
}, []);

// Valid subfolder names inside a feature/service module (lowercase for comparison)
const KNOWN_SUBFOLDERS = new Set(["server", "client", "shared", "network", "ui", "assets"]);

// ── Routing ───────────────────────────────────────────────────────────────────

/**
 * Determines the Rojo routing for a single .luau file.
 * Returns a routing object or null if the file should be skipped.
 */
function getVirtualPath(filepath) {
	const relativePath = path.relative(BASE_PATH, filepath);
	const parts = relativePath.split(path.sep);
	const filename = path.basename(filepath, ".luau");
	const lowerFilename = filename.toLowerCase();

	const isFeature = hasFeatures && parts[0] === featuresDir;
	const isService = hasServices && parts[0] === servicesDir;

	if (isFeature || isService) {
		const moduleType = isFeature ? "features" : "services";
		const moduleName = parts[1];
		const subFolder = parts[2];
		const subFolderLower = subFolder ? subFolder.toLowerCase() : null;
		const destinationFolder = moduleType === "features" ? "Features" : "Services";
		let name = filename;

		// ── network/ ────────────────────────────────────────────────────────────
		if (subFolderLower === "network") {
			const networkFilename = parts[3];
			const isServer = networkFilename && networkFilename.toLowerCase() === "server.luau";
			return {
				target: isServer ? "ServerScriptService" : "ReplicatedStorage",
				folder: [destinationFolder, moduleName],
				name: isServer ? "NetworkServer" : "NetworkClient",
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── ui/ ─────────────────────────────────────────────────────────────────
		if (subFolderLower === "ui") {
			// Always point at the ui/ directory itself regardless of nesting depth
			const uiSegmentIndex = parts.map((p) => p.toLowerCase()).indexOf("ui");
			const uiAbsPath = path.join(BASE_PATH, ...parts.slice(0, uiSegmentIndex + 1));
			return {
				target: "ReplicatedStorage",
				folder: [destinationFolder, moduleName],
				name: "UI",
				isUIFolder: true,
				uiPath: toSrcDir(uiAbsPath),
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── assets/ ─────────────────────────────────────────────────────────────
		// Asset folders are registered via scanModuleAssets() after the walk, not
		// per-file. Any .luau accidentally placed inside assets/ is silently skipped
		// rather than incorrectly routed.
		if (subFolderLower === "assets") {
			return null;
		}

		// ── server/ ─────────────────────────────────────────────────────────────
		if (subFolderLower === "server") {
			const nestedFolders = parts.slice(3, -1);
			const folderPath = [destinationFolder, moduleName, ...nestedFolders];
			if (lowerFilename === "init") name = toPascalCase(parts[parts.length - 2]);
			return {
				target: "ServerScriptService",
				folder: folderPath,
				name,
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── client/ ─────────────────────────────────────────────────────────────
		// Client-only modules. Routed to ReplicatedStorage so the client runtime
		// can require them, but the server never has reason to touch them.
		// Prefer over shared/ when code is intentionally client-only.
		if (subFolderLower === "client") {
			const nestedFolders = parts.slice(3, -1);
			const folderPath = [destinationFolder, moduleName, ...nestedFolders];
			if (lowerFilename === "init") name = toPascalCase(parts[parts.length - 2]);
			return {
				target: "ReplicatedStorage",
				folder: folderPath,
				name,
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── shared/ ─────────────────────────────────────────────────────────────
		if (subFolderLower === "shared") {
			const nestedFolders = parts.slice(3, -1);
			const folderPath = [destinationFolder, moduleName, ...nestedFolders];
			if (lowerFilename === "init") name = toPascalCase(parts[parts.length - 2]);
			return {
				target: "ReplicatedStorage",
				folder: folderPath,
				name,
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── Root-level files in the module (e.g. InventoryServer.luau) ──────────
		if (parts.length === 3) {
			const isServerFile = lowerFilename.includes("server");
			return {
				target: isServerFile ? "ServerScriptService" : "ReplicatedStorage",
				folder: [destinationFolder, moduleName],
				name,
				file: toSrcPath(filepath),
				moduleType,
				moduleName,
			};
		}

		// ── Unrecognized subfolder ───────────────────────────────────────────────
		// parts.length > 3 and subFolder didn't match any known type.
		// Warn rather than silently routing to the wrong place.
		console.warn(
			`⚠ Unrecognized subfolder "${subFolder}" in ${moduleType}/${moduleName} — skipping:\n` +
				`    ${toPosix(relativePath)}\n` +
				`  Valid subfolders: ${[...KNOWN_SUBFOLDERS].join(", ")}`,
		);
		return null;
	}

	// ── Fallback for files outside features/ and services/ ───────────────────────
	return {
		target: "ReplicatedStorage",
		folder: parts.slice(0, -1).map(toPascalCase),
		name: filename,
		file: toSrcPath(filepath),
	};
}

// ── Build the static base tree ────────────────────────────────────────────────

const replicatedStorage = { $className: "ReplicatedStorage" };
if (hasFeatures) replicatedStorage.Features = { $className: "Folder" };
if (hasServices) replicatedStorage.Services = { $className: "Folder" };
if (sharedDir) replicatedStorage.Shared = { $className: "Folder", $path: `src/${sharedDir}` };
if (assetsDir && pathExists(path.join(BASE_PATH, assetsDir, "Shared")))
	replicatedStorage.Assets = { $className: "Folder", $path: `src/${assetsDir}/Shared` };
if (uiDir) replicatedStorage.UI = { $className: "Folder", $path: `src/${uiDir}` };
if (pathExists("Packages")) replicatedStorage.Packages = { $path: "Packages" };

const serverScriptService = { $className: "ServerScriptService" };
if (hasFeatures) serverScriptService.Features = { $className: "Folder" };
if (hasServices) serverScriptService.Services = { $className: "Folder" };
if (startupDir && pathExists(path.join(BASE_PATH, startupDir, "Server.server.luau")))
	serverScriptService.ServerStartup = { $path: `src/${startupDir}/Server.server.luau` };
if (pathExists("ServerPackages")) serverScriptService.ServerPackages = { $path: "ServerPackages" };

// ServerStorage: Features/Services containers are added as placeholders and
// populated (or pruned) by scanModuleAssets() below.
const serverStorage = { $className: "ServerStorage" };
if (hasFeatures) serverStorage.Features = { $className: "Folder" };
if (hasServices) serverStorage.Services = { $className: "Folder" };
if (assetsDir && pathExists(path.join(BASE_PATH, assetsDir, "Server")))
	serverStorage.Assets = { $className: "Folder", $path: `src/${assetsDir}/Server` };

const starterPlayerScripts = { $className: "StarterPlayerScripts" };
if (startupDir && pathExists(path.join(BASE_PATH, startupDir, "Client.client.luau")))
	starterPlayerScripts.ClientStartup = { $path: `src/${startupDir}/Client.client.luau` };
if (startupDir && pathExists(path.join(BASE_PATH, startupDir, "UI.client.luau")))
	starterPlayerScripts.UIStartup = { $path: `src/${startupDir}/UI.client.luau` };

const hasStarterScripts = Object.keys(starterPlayerScripts).filter((k) => k !== "$className").length > 0;

const tree = {
	name: PROJECT_NAME,
	tree: {
		$className: "DataModel",
		ReplicatedStorage: replicatedStorage,
		ServerStorage: serverStorage,
		ServerScriptService: serverScriptService,
		...(hasStarterScripts
			? {
					StarterPlayer: {
						$className: "StarterPlayer",
						StarterPlayerScripts: starterPlayerScripts,
					},
				}
			: {}),
	},
};

// ── Convenience references into the mutable tree ─────────────────────────────
const replicatedFeatures = hasFeatures ? replicatedStorage.Features : null;
const replicatedServices = hasServices ? replicatedStorage.Services : null;
const serverFeatures = hasFeatures ? serverScriptService.Features : null;
const serverServices = hasServices ? serverScriptService.Services : null;
const storageFeatures = hasFeatures ? serverStorage.Features : null;
const storageServices = hasServices ? serverStorage.Services : null;

// ── Tree navigation helpers ───────────────────────────────────────────────────

/** Resolve the correct root container node for a routing result. */
function resolveRoot(target, folder) {
	const isFeatureFolder = folder[0] === "Features";
	if (target === "ServerScriptService") {
		return isFeatureFolder ? serverFeatures : serverServices;
	}
	return isFeatureFolder ? replicatedFeatures : replicatedServices;
}

/**
 * Navigate from a root container through a folder path, creating intermediate
 * Folder nodes as needed. folder[0] is always "Features" or "Services" and is
 * skipped since root already points inside that container.
 */
function navigateTo(root, folder) {
	let current = root;
	for (let i = 1; i < folder.length; i++) {
		const part = folder[i];
		if (!current[part]) current[part] = { $className: "Folder" };
		current = current[part];
	}
	return current;
}

// ── Walk the file system ──────────────────────────────────────────────────────
function walk(dir, callback) {
	if (BLACKLISTED_DIRS.includes(toPosix(dir))) return;
	if (!pathExists(dir)) return;

	let entries;
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch (err) {
		console.warn(`⚠ Could not read directory: ${dir} (${err.message})`);
		return;
	}

	for (const entry of entries) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			walk(full, callback);
		} else if (entry.isFile() && entry.name.endsWith(".luau")) {
			callback(full);
		}
	}
}

// ── Process all files ─────────────────────────────────────────────────────────
const initClaimedFolders = new Set();
const uiFolderPaths = new Map(); // folderKey → src/-relative ui dir path

walk(BASE_PATH, (filepath) => {
	const info = getVirtualPath(filepath);

	// null = skip (assets subfolder or unrecognized subfolder — already warned)
	if (info === null) return;

	// ── UI folder — record the $path once, skip individual files ───────────────
	if (info.isUIFolder) {
		const key = info.folder.join("/") + "/UI";
		if (!uiFolderPaths.has(key)) uiFolderPaths.set(key, info.uiPath);
		return;
	}

	const { target, folder, name, file } = info;
	const root = resolveRoot(target, folder);
	if (!root) return;

	const lowerFilename = path.basename(filepath, ".luau").toLowerCase();

	// ── init.luau — the file represents its containing directory ───────────────
	if (lowerFilename === "init") {
		const folderKey = folder.join("/");
		initClaimedFolders.add(folderKey);

		// Navigate to the parent and overwrite whatever is there (including any
		// Folder stub that navigateTo may have created for sibling files processed
		// earlier) with a $path pointing at the whole directory.
		const parent = navigateTo(root, folder.slice(0, -1));
		parent[folder[folder.length - 1]] = { $path: toSrcDir(path.dirname(filepath)) };
		return;
	}

	// Skip files whose parent folder is already claimed by an init.luau
	if (initClaimedFolders.has(folder.join("/"))) return;

	const current = navigateTo(root, folder);
	current[name] = { $path: file };
});

// ── Apply collected UI $path references ──────────────────────────────────────
for (const [key, uiDirPath] of uiFolderPaths.entries()) {
	const parts = key.split("/");
	const root = parts[0] === "Features" ? replicatedFeatures : replicatedServices;
	if (!root) continue;
	const parent = navigateTo(root, parts.slice(0, -1));
	parent.UI = { $path: uiDirPath };
}

// ── Scan for per-module asset folders ────────────────────────────────────────
// Mirrors the global src/assets/ layout at the feature/service level:
//
//   module/assets/Shared/  →  ReplicatedStorage > Features/Services > ModuleName > Assets
//   module/assets/Server/  →  ServerStorage     > Features/Services > ModuleName > Assets
//   module/assets/         →  ReplicatedStorage > Features/Services > ModuleName > Assets
//     (a bare assets/ with no Shared/ or Server/ subfolders is treated as fully shared)
//
// replicatedRoot and storageRoot are the containers already inside Features/Services,
// so indexing by moduleName directly places entries in the right spot.

function scanModuleAssets(moduleRootDir, replicatedRoot, storageRoot) {
	if (!pathExists(moduleRootDir)) return;

	let moduleDirs;
	try {
		moduleDirs = fs.readdirSync(moduleRootDir, { withFileTypes: true }).filter((e) => e.isDirectory());
	} catch {
		return;
	}

	for (const moduleEntry of moduleDirs) {
		const moduleName = moduleEntry.name;
		const moduleDir = path.join(moduleRootDir, moduleName);

		const assetsSubdir = findDir(moduleDir, "assets");
		if (!assetsSubdir) continue;

		const assetsDirAbs = path.join(moduleDir, assetsSubdir);
		const sharedSubdir = findDir(assetsDirAbs, "shared");
		const serverSubdir = findDir(assetsDirAbs, "server");
		const hasSplit = sharedSubdir !== null || serverSubdir !== null;

		// Ensure the module folder node exists in the container before adding Assets
		function setAssets(container, assetDirAbs) {
			if (!container) return;
			if (!container[moduleName]) container[moduleName] = { $className: "Folder" };
			container[moduleName].Assets = { $path: toSrcDir(assetDirAbs) };
		}

		if (hasSplit) {
			if (sharedSubdir) setAssets(replicatedRoot, path.join(assetsDirAbs, sharedSubdir));
			if (serverSubdir) setAssets(storageRoot, path.join(assetsDirAbs, serverSubdir));
		} else {
			setAssets(replicatedRoot, assetsDirAbs);
		}
	}
}

if (hasFeatures) {
	scanModuleAssets(path.join(BASE_PATH, featuresDir), replicatedFeatures, storageFeatures);
}
if (hasServices) {
	scanModuleAssets(path.join(BASE_PATH, servicesDir), replicatedServices, storageServices);
}

// ── Prune empty placeholder nodes ────────────────────────────────────────────
// If no module assets ended up in ServerStorage.Features or .Services, remove
// those placeholder folders so they don't appear as empty containers in-game.
// If ServerStorage itself ends up with no content at all, remove it too.

function pruneEmpty(parent, key) {
	const node = parent[key];
	if (!node) return;
	const childKeys = Object.keys(node).filter((k) => k !== "$className");
	if (childKeys.length === 0) delete parent[key];
}

pruneEmpty(serverStorage, "Features");
pruneEmpty(serverStorage, "Services");
pruneEmpty(tree.tree, "ServerStorage");

// ── Write output ──────────────────────────────────────────────────────────────
fs.writeFileSync("default.project.json", JSON.stringify(tree, null, 2));
console.log("✅ default.project.json generated.");
