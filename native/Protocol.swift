import AppKit
import ApplicationServices

struct DriverError: Error {
    let code: String
    let message: String
    var actionExecuted = false
}
struct Request: Decodable {
    let id: Int
    let method: String
    var params: Parameters
}
struct Parameters: Decodable {
    var app: String?
    var pid: Int32?
    var window_id: UInt32?
    var snapshot_id: String?
    var element: Int?
    var x: Double?
    var y: Double?
    var to_x: Double?
    var to_y: Double?
    var text: String?
    var key: String?
    var button: String?
    var count: Int?
    var delta_x: Int32?
    var delta_y: Int32?
    var duration_ms: Int?
    var include_image: Bool?
    var max_elements: Int?
    var timeout_ms: Int?
}
func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw DriverError(code:"INVALID_ARGUMENT",message:"Missing \(name)") }
    return value
}
func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
}
func axString(_ element: AXUIElement, _ key: String) -> String { axValue(element,key) as? String ?? "" }
func axBool(_ element: AXUIElement, _ key: String) -> Bool? { axValue(element,key) as? Bool }
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p=axValue(element,kAXPositionAttribute), let s=axValue(element,kAXSizeAttribute), CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else {return nil}
    var point=CGPoint.zero, size=CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else {return nil}
    return CGRect(origin:point,size:size)
}
func rectJSON(_ rect:CGRect)->[String:Double]{["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height]}
func keyFocusPID()->Int32? {var pid:Int32=0;return dsh_key_focus_pid(&pid)==0 ? pid:nil}
func jsonOptional<T>(_ value:T?)->Any {value.map{$0 as Any} ?? NSNull()}
func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {throw DriverError(code:"ACCESSIBILITY_REQUIRED",message:"Grant Accessibility to the application hosting this driver, then restart the driver. No permission was requested automatically.")}
}
