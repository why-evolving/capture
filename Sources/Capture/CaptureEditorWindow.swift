import AppKit

/// Native responder actions preserve text-field editing and make menu shortcuts reliable.
@MainActor
final class CaptureEditorWindow: NSWindow {
    weak var captureDocument: CaptureDocument?
    weak var captureApp: AppController?
    @objc func copy(_ sender: Any?) {
        guard let captureDocument, let captureApp else { return }
        Task { await captureApp.copy(captureDocument) }
    }
    @objc func undo(_ sender: Any?) {
        if let text = firstResponder as? NSTextView { if text.undoManager?.canUndo == true { text.undoManager?.undo() }; return }
        captureDocument?.undo()
    }
    @objc func redo(_ sender: Any?) {
        if let text = firstResponder as? NSTextView { if text.undoManager?.canRedo == true { text.undoManager?.redo() }; return }
        captureDocument?.redo()
    }
    @objc func paste(_ sender: Any?) { captureApp?.importClipboard() }
    @objc func saveProject(_ sender: Any?) { if let captureDocument { captureApp?.saveProject(captureDocument) } }
    @objc func saveDocument(_ sender: Any?) { if let captureDocument { captureApp?.save(captureDocument) } }
    override func deleteBackward(_ sender: Any?) {
        if let document = captureDocument, let id = document.selectedAnnotationID { document.deleteAnnotation(id) }
    }
    override func deleteForward(_ sender: Any?) { deleteBackward(sender) }
    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           captureDocument?.selectedAnnotationID != nil { deleteBackward(nil) }
        else { super.keyDown(with: event) }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return (firstResponder as? NSTextView).map { $0.undoManager?.canUndo ?? false } ?? (captureDocument?.canUndo ?? false)
        case #selector(redo(_:)): return (firstResponder as? NSTextView).map { $0.undoManager?.canRedo ?? false } ?? (captureDocument?.canRedo ?? false)
        case #selector(copy(_:)): return captureDocument != nil && captureApp?.copying == false
        case #selector(saveProject(_:)): return captureDocument != nil && captureApp?.saving == false
        case #selector(saveDocument(_:)): return captureDocument != nil && captureApp?.saving == false
        case #selector(paste(_:)): return captureApp != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
