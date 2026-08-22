import WebKit

/// Validated state sent by the semantic settings-dialog observer. The mask
/// color remains optional so the native side can use a safe fallback if a
/// future dsh theme no longer exposes its current design token.
struct SettingsPresentationState: Equatable {
  let isOpen: Bool
  let mask: PageRGBAColor?

  init?(body: Any) {
    guard let json = body as? [String: Any], let isOpen = json["open"] as? Bool else {
      return nil
    }
    if let rawMask = json["maskRGBA"] {
      guard let mask = PageRGBAColor(jsonValue: rawMask) else { return nil }
      self.mask = mask
    } else {
      mask = nil
    }
    self.isOpen = isOpen
  }
}

/// A shell-only presentation adjustment for DSH's existing settings dialog.
/// It deliberately targets semantic dialog structure instead of CSS-module
/// class names so a normal dsh update does not invalidate the Mac app.
enum SettingsPresentation {
  static let markerAttribute = "data-dsh-mac-settings-dialog"
  static let messageName = "dshSettingsPresentation"

  static let script = WKUserScript(
    source: """
    (function () {
      const marker = '\(markerAttribute)';
      const styleId = 'dsh-mac-settings-presentation';
      const handler = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.\(messageName);
      let lastPayload = '';
      const canvas = document.createElement('canvas');
      canvas.width = 1;
      canvas.height = 1;
      const context = canvas.getContext('2d', { willReadFrequently: true });

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

      const maskRGBA = function () {
        const themeRoot = document.body || document.documentElement;
        if (!themeRoot || !context) return null;
        const value = getComputedStyle(themeRoot)
          .getPropertyValue('--dsw-alias-bg-mask-1').trim();
        if (!value) return null;
        context.clearRect(0, 0, 1, 1);
        context.fillStyle = 'rgba(0, 0, 0, 0)';
        context.fillStyle = value;
        context.fillRect(0, 0, 1, 1);
        const result = Array.from(context.getImageData(0, 0, 1, 1).data);
        return result[3] > 0 ? result : null;
      };

      const notifyNative = function (dialog) {
        if (!handler) return;
        const payload = { open: !!dialog };
        if (dialog) {
          const rgba = maskRGBA();
          if (rgba) payload.maskRGBA = rgba;
        }
        const serialized = JSON.stringify(payload);
        if (serialized === lastPayload) return;
        lastPayload = serialized;
        try { handler.postMessage(payload); } catch (e) {}
      };

      const annotate = function () {
        let settingsDialog = null;
        document.querySelectorAll('[role="dialog"][aria-modal="true"]').forEach(
          function (dialog) {
            if (!isSettingsDialog(dialog)) return;
            if (!dialog.hasAttribute(marker)) dialog.setAttribute(marker, '');
            if (!settingsDialog && dialog.getClientRects().length > 0) settingsDialog = dialog;
          });
        notifyNative(settingsDialog);
      };

      installStyle();
      annotate();
      const observer = new MutationObserver(annotate);
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class', 'style', 'data-ds-dark-theme']
      });
    })();
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true)
}
