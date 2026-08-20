/**
 * ============================================================
 * bve512-browser.js — BVE-512 pour navigateur
 * ============================================================
 * Version adaptée pour tourner directement dans le HTML/JS
 * d'une page web, sans Node.js. Utilise le Web Crypto API
 * natif du navigateur (crypto.subtle, crypto.getRandomValues)
 * — aucune dépendance externe, aucune librairie à charger.
 *
 * Inclus dans une page HTML via :
 *   <script src="bve512-browser.js"></script>
 * Toutes les fonctions sont ensuite disponibles sous BVE512.*
 *
 * ⚠️ Rappel : la "clé publique" est une étiquette cosmétique
 * (multiplication réversible), pas une sécurité asymétrique.
 * Garde la clé privée ET la clé publique confidentielles.
 * ============================================================
 */

const BVE512 = (() => {

  // ------------------------------------------------------------
  // SHA-256 via Web Crypto API (asynchrone -> toutes les fonctions
  // qui en dépendent sont donc aussi asynchrones dans cette version)
  // ------------------------------------------------------------
  async function sha256(bytes) {
    const hashBuffer = await crypto.subtle.digest('SHA-256', bytes);
    return new Uint8Array(hashBuffer);
  }

  function textToBytes(str) {
    return new TextEncoder().encode(str);
  }

  function bytesToHex(bytes) {
    return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  function hexToBytes(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
      bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
  }

  function concatBytes(...arrays) {
    const total = arrays.reduce((sum, a) => sum + a.length, 0);
    const out = new Uint8Array(total);
    let offset = 0;
    for (const a of arrays) { out.set(a, offset); offset += a.length; }
    return out;
  }

  // ------------------------------------------------------------
  // Génération de la S-box (asynchrone, car dépend de SHA-256)
  // ------------------------------------------------------------
  async function generateSbox(seed) {
    let state = await sha256(textToBytes(seed));
    let pos = 0;

    async function nextByte() {
      if (pos >= state.length) {
        state = await sha256(state);
        pos = 0;
      }
      return state[pos++];
    }

    const sbox = Array.from({ length: 256 }, (_, i) => i);
    for (let i = 255; i > 0; i--) {
      let r, limit = 256 - (256 % (i + 1));
      do {
        r = await nextByte();
      } while (r >= limit);
      const j = r % (i + 1);
      [sbox[i], sbox[j]] = [sbox[j], sbox[i]];
    }
    return sbox;
  }

  // ------------------------------------------------------------
  // Condensation clé utilisateur -> 512 bits
  // ------------------------------------------------------------
  async function condenseKeyTo512Bits(userKey) {
    let keyMaterial = new Uint8Array(0);
    let counter = 0;
    while (keyMaterial.length < 64) {
      const chunk = await sha256(textToBytes(`${userKey}-${counter}`));
      keyMaterial = concatBytes(keyMaterial, chunk);
      counter++;
    }
    return keyMaterial.subarray(0, 64);
  }

  // ------------------------------------------------------------
  // Utilitaires bas niveau
  // ------------------------------------------------------------
  function rotl32(x, n) {
    n = n % 32;
    x = x >>> 0;
    return ((x << n) | (x >>> (32 - n))) >>> 0;
  }

  function subBytesArray(arr, sbox) {
    const out = new Uint8Array(arr.length);
    for (let i = 0; i < arr.length; i++) out[i] = sbox[arr[i]];
    return out;
  }

  function subBytes32(val, sbox) {
    const buf = new Uint8Array(4);
    new DataView(buf.buffer).setUint32(0, val >>> 0, false);
    const sub = subBytesArray(buf, sbox);
    return new DataView(sub.buffer).getUint32(0, false);
  }

  // ------------------------------------------------------------
  // Key schedule
  // ------------------------------------------------------------
  function deriveRoundKey(livre, roundNum, sbox) {
    let val = subBytes32(new DataView(livre.buffer, livre.byteOffset).getUint32(0, false), sbox);
    const roundMask = (roundNum * 0x9E3779B1) >>> 0;
    val = (val ^ roundMask) >>> 0;
    val = subBytes32(val, sbox);
    val = rotl32(val, roundNum % 32);
    return val >>> 0;
  }

  async function fullKeySchedule(userKey512chars, sbox) {
    const key512bits = await condenseKeyTo512Bits(userKey512chars);
    const livres = [];
    for (let i = 0; i < 16; i++) livres.push(key512bits.subarray(i * 4, i * 4 + 4));

    const roundKeys = [];
    for (let i = 1; i <= 32; i++) {
      const livreIndex = (i - 1) % 16;
      roundKeys.push(deriveRoundKey(livres[livreIndex], i, sbox));
    }
    return roundKeys;
  }

  // ------------------------------------------------------------
  // Fonction de ronde F (BigInt, 64 bits)
  // ------------------------------------------------------------
  function expandRkTo64(rk32, sbox) {
    const haut = BigInt(rk32);
    const bas = BigInt(subBytes32(rk32, sbox) ^ 0xA5A5A5A5) & 0xFFFFFFFFn;
    return (haut << 32n) | bas;
  }

  function diffusion(val) {
    let b = [];
    for (let i = 7; i >= 0; i--) b.push(Number((val >> BigInt(i * 8)) & 0xFFn));

    const offsets = [1, 2, 3, 5];
    const rotations = [1, 3, 5, 7];

    for (let k = 0; k < 4; k++) {
      const offset = offsets[k], rot = rotations[k];
      const newB = new Array(8);
      for (let i = 0; i < 8; i++) {
        const neighbor = b[(i + offset) % 8];
        const rotated = ((neighbor << rot) | (neighbor >>> (8 - rot))) & 0xFF;
        newB[i] = b[i] ^ rotated;
      }
      b = newB;
    }

    let out = 0n;
    for (let i = 0; i < 8; i++) out = (out << 8n) | BigInt(b[i]);
    return out;
  }

  function subBytes64(val, sbox) {
    const buf = new Uint8Array(8);
    for (let i = 7; i >= 0; i--) buf[7 - i] = Number((val >> BigInt(i * 8)) & 0xFFn);
    const sub = subBytesArray(buf, sbox);
    let out = 0n;
    for (let i = 0; i < 8; i++) out = (out << 8n) | BigInt(sub[i]);
    return out;
  }

  function roundFunctionF(droite, rk32, sbox) {
    const rk64 = expandRkTo64(rk32, sbox);
    let val = droite ^ rk64;
    val = subBytes64(val, sbox);
    val = diffusion(val);
    val = subBytes64(val, sbox);
    return val;
  }

  // ------------------------------------------------------------
  // Chiffrement / déchiffrement d'un bloc
  // ------------------------------------------------------------
  const MASK64 = (1n << 64n) - 1n;

  function encryptBlock(bloc128, roundKeys, sbox) {
    let gauche = (bloc128 >> 64n) & MASK64;
    let droite = bloc128 & MASK64;
    for (let i = 0; i < 32; i++) {
      const ng = droite;
      const nd = gauche ^ roundFunctionF(droite, roundKeys[i], sbox);
      gauche = ng; droite = nd;
    }
    return (gauche << 64n) | droite;
  }

  function decryptBlock(blocChiffre128, roundKeys, sbox) {
    let gauche = (blocChiffre128 >> 64n) & MASK64;
    let droite = blocChiffre128 & MASK64;
    for (let i = 31; i >= 0; i--) {
      const nd = gauche;
      const ng = droite ^ roundFunctionF(gauche, roundKeys[i], sbox);
      gauche = ng; droite = nd;
    }
    return (gauche << 64n) | droite;
  }

  // ------------------------------------------------------------
  // Padding PKCS7
  // ------------------------------------------------------------
  function pkcs7Pad(data, blockSize = 16) {
    const padLen = blockSize - (data.length % blockSize);
    return concatBytes(data, new Uint8Array(padLen).fill(padLen));
  }

  function pkcs7Unpad(data) {
    const padLen = data[data.length - 1];
    return data.subarray(0, data.length - padLen);
  }

  function xorBytes(a, b) {
    const out = new Uint8Array(a.length);
    for (let i = 0; i < a.length; i++) out[i] = a[i] ^ b[i];
    return out;
  }

  function bytesToBigInt(bytes) {
    return BigInt('0x' + bytesToHex(bytes));
  }

  function bigIntToBytes(val, length = 16) {
    let hex = val.toString(16).padStart(length * 2, '0');
    return hexToBytes(hex);
  }

  // ------------------------------------------------------------
  // Mode CBC
  // ------------------------------------------------------------
  function encryptCBC(message, roundKeys, sbox, iv = null) {
    if (iv === null) {
      iv = new Uint8Array(16);
      crypto.getRandomValues(iv);
    }

    const data = pkcs7Pad(textToBytes(message));
    const nbBlocs = data.length / 16;

    const blocsChiffres = [];
    let blocPrecedent = iv;
    for (let i = 0; i < nbBlocs; i++) {
      const bloc = data.subarray(i * 16, i * 16 + 16);
      const bXor = xorBytes(bloc, blocPrecedent);
      const chiffreInt = encryptBlock(bytesToBigInt(bXor), roundKeys, sbox);
      const chiffreBytes = bigIntToBytes(chiffreInt);
      blocsChiffres.push(chiffreBytes);
      blocPrecedent = chiffreBytes;
    }

    return { iv, blocsChiffres };
  }

  function decryptCBC(iv, blocsChiffres, roundKeys, sbox) {
    let data = new Uint8Array(0);
    let blocPrecedent = iv;
    for (const c of blocsChiffres) {
      const dechiffreInt = decryptBlock(bytesToBigInt(c), roundKeys, sbox);
      const dechiffreBytes = bigIntToBytes(dechiffreInt);
      const original = xorBytes(dechiffreBytes, blocPrecedent);
      data = concatBytes(data, original);
      blocPrecedent = c;
    }
    return new TextDecoder().decode(pkcs7Unpad(data));
  }

  // ------------------------------------------------------------
  // API haut niveau (asynchrone : utiliser await ou .then())
  // ------------------------------------------------------------
  async function encrypt(message, privateKey512chars, seedbox) {
    const sbox = await generateSbox(seedbox);
    const roundKeys = await fullKeySchedule(privateKey512chars, sbox);
    const { iv, blocsChiffres } = encryptCBC(message, roundKeys, sbox);
    return bytesToHex(iv) + blocsChiffres.map(bytesToHex).join('');
  }

  async function decrypt(hexMessage, privateKey512chars, seedbox) {
    const sbox = await generateSbox(seedbox);
    const roundKeys = await fullKeySchedule(privateKey512chars, sbox);

    const iv = hexToBytes(hexMessage.slice(0, 32));
    const restHex = hexMessage.slice(32);
    const blocsChiffres = [];
    for (let i = 0; i < restHex.length; i += 32) {
      blocsChiffres.push(hexToBytes(restHex.slice(i, i + 32)));
    }

    return decryptCBC(iv, blocsChiffres, roundKeys, sbox);
  }

  // ------------------------------------------------------------
  // Génération de clés (privée + publique cosmétique)
  // ------------------------------------------------------------
  const CHARSET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const PUBLIC_KEY_MULTIPLIER = 104729n;

  function generatePrivateKey(length = 512) {
    const bytes = new Uint8Array(length);
    crypto.getRandomValues(bytes);
    let key = '';
    for (let i = 0; i < length; i++) key += CHARSET[bytes[i] % CHARSET.length];
    return key;
  }

  function generateSeedbox() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return bytesToHex(bytes);
  }

  function privateKeyToPublicKey(privateKey512chars) {
    const asBytes = textToBytes(privateKey512chars);
    const asBigInt = bytesToBigInt(asBytes);
    const publicBigInt = asBigInt * PUBLIC_KEY_MULTIPLIER;
    return publicBigInt.toString(16);
  }

  function publicKeyToPrivateKey(publicKeyHex) {
    const publicBigInt = BigInt('0x' + publicKeyHex);
    const privateBigInt = publicBigInt / PUBLIC_KEY_MULTIPLIER;
    let hex = privateBigInt.toString(16);
    if (hex.length % 2 !== 0) hex = '0' + hex;
    return new TextDecoder().decode(hexToBytes(hex));
  }

return {
  encrypt,
  decrypt,
  generatePrivateKey,
  generateSeedbox,
  privateKeyToPublicKey,
  publicKeyToPrivateKey,
};

})();

window.BVE512 = BVE512;
