/* ============================================================
   Moteur de langue Français / Bintuk
   - Le français reste toujours le texte "source" écrit dans le HTML.
   - Les traductions Bintuk vivent dans traduction/<page>.json
     (une clé data-i18n="xxx" par bout de texte traduisible).
   - Rien n'est modifié dans le HTML/CSS existant : ce fichier ne
     fait que lire les attributs data-i18n déjà posés et échanger
     le texte au clic sur le bouton (ex-"Français", maintenant
     "Bintuk").
   ============================================================ */
(function () {
  const CLE_LANGUE = 'etalie_langue'; // 'fr' ou 'bin'

  function langueActuelle() {
    return localStorage.getItem(CLE_LANGUE) || 'fr';
  }

  function nomPage() {
    return document.body.getAttribute('data-page') || 'index';
  }

  async function chargerDictionnaire() {
    try {
      const [reponsePage, reponseUniversel] = await Promise.all([
        fetch(`traduction/${nomPage()}.json`, { cache: 'no-store' }),
        fetch('translation/others/dates_et_taille.json', { cache: 'no-store' }),
      ]);
      const dictPage = reponsePage.ok ? await reponsePage.json() : {};
      const dictUniversel = reponseUniversel.ok ? await reponseUniversel.json() : {};
      // Le dictionnaire universel (tdlXXX, panneau Paramètres) est
      // disponible sur toutes les pages, fusionné avec celui de la page.
      return { ...dictUniversel, ...dictPage };
    } catch (e) {
      console.warn('Traduction indisponible pour cette page :', e);
      return {};
    }
  }

  function appliquerBintuk(dict) {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const cle = el.getAttribute('data-i18n');
      if (!el.hasAttribute('data-i18n-fr')) {
        el.setAttribute('data-i18n-fr', el.textContent);
      }
      if (dict[cle]) el.textContent = dict[cle];
    });

    document.querySelectorAll('[data-i18n-ph]').forEach((el) => {
      const cle = el.getAttribute('data-i18n-ph');
      if (!el.hasAttribute('data-i18n-ph-fr')) {
        el.setAttribute('data-i18n-ph-fr', el.getAttribute('placeholder') || '');
      }
      if (dict[cle]) el.setAttribute('placeholder', dict[cle]);
    });

    document.querySelectorAll('[data-i18n-titre]').forEach((el) => {
      const cle = el.getAttribute('data-i18n-titre');
      if (!el.hasAttribute('data-i18n-titre-fr')) {
        el.setAttribute('data-i18n-titre-fr', el.getAttribute('title') || '');
      }
      if (dict[cle]) el.setAttribute('title', dict[cle]);
    });
  }

  function restaurerFrancais() {
    document.querySelectorAll('[data-i18n-fr]').forEach((el) => {
      el.textContent = el.getAttribute('data-i18n-fr');
    });
    document.querySelectorAll('[data-i18n-ph-fr]').forEach((el) => {
      el.setAttribute('placeholder', el.getAttribute('data-i18n-ph-fr'));
    });
    document.querySelectorAll('[data-i18n-titre-fr]').forEach((el) => {
      el.setAttribute('title', el.getAttribute('data-i18n-titre-fr'));
    });
  }

  async function appliquerLangue(langue) {
    if (langue === 'bin') {
      const dict = await chargerDictionnaire();
      appliquerBintuk(dict);
    } else {
      restaurerFrancais();
    }
  }

  // Exposée pour le bouton "Bintuk" dans le bandeau utilitaire
  window.basculerLangue = async function () {
    const nouvelle = langueActuelle() === 'bin' ? 'fr' : 'bin';
    localStorage.setItem(CLE_LANGUE, nouvelle);
    await appliquerLangue(nouvelle);
  };

  document.addEventListener('DOMContentLoaded', () => {
    appliquerLangue(langueActuelle());
  });
})();
