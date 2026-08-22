import WebKit

/// A shell-only presentation adjustment for DSH's existing settings dialog.
/// It deliberately targets semantic dialog structure instead of CSS-module
/// class names so a normal dsh update does not invalidate the Mac app.
enum SettingsPresentation {
  static let markerAttribute = "data-dsh-mac-settings-dialog"

  static let script = WKUserScript(
    source: """
    (function () {
      const marker = '\(markerAttribute)';
      const styleId = 'dsh-mac-settings-presentation';

      const installStyle = function () {
        if (document.getElementById(styleId)) return;
        const style = document.createElement('style');
        style.id = styleId;
        style.textContent = `
          [${marker}] {
            height: auto !important;
            min-height: min(520px, calc(100vh - 64px)) !important;
            max-height: min(720px, calc(100vh - 64px)) !important;
          }
          [${marker}] > nav {
            min-height: 0;
            padding-bottom: 18px;
          }
          [${marker}] > nav > div:last-child {
            min-height: 0;
            overflow-y: auto;
          }
        `;
        (document.head || document.documentElement).appendChild(style);
      };

      const isSettingsDialog = function (dialog) {
        if (!(dialog instanceof Element) || !dialog.matches(
          '[role="dialog"][aria-modal="true"]')) return false;
        const labelledBy = dialog.getAttribute('aria-labelledby');
        const title = labelledBy ? document.getElementById(labelledBy) : null;
        const titleText = title ? (title.textContent || '').trim() : '';
        return !!dialog.querySelector(':scope > nav') && /^(设置|settings)$/i.test(titleText);
      };

      const annotate = function () {
        document.querySelectorAll('[role="dialog"][aria-modal="true"]').forEach(
          function (dialog) {
            if (isSettingsDialog(dialog)) dialog.setAttribute(marker, '');
          });
      };

      installStyle();
      annotate();
      const observer = new MutationObserver(annotate);
      observer.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true)
}
