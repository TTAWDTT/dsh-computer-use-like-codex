import AppKit
let root=ProcessInfo.processInfo.environment["DSH_FIXTURE_DIR"]!
let foreground=Bundle.main.bundleIdentifier!.hasSuffix("foreground")
let role=ProcessInfo.processInfo.environment["DSH_FIXTURE_ROLE"] ?? (foreground ? "foreground":"target")
func log(_ event:String,_ data:[String:Any]=[:]){
    var row=data;row["event"]=event;row["wall_ms"]=Date().timeIntervalSince1970*1000
    if let d=try? JSONSerialization.data(withJSONObject:row),let h=FileHandle(forWritingAtPath:root+"/"+role+".jsonl"){h.seekToEndOfFile();h.write(d);h.write(Data([10]));try? h.close()}
}
class App:NSApplication{
    override func sendEvent(_ e:NSEvent){
        if [.leftMouseDown,.leftMouseUp,.leftMouseDragged,.keyDown,.keyUp,.scrollWheel].contains(e.type){
            var d:[String:Any]=["type":e.type.rawValue,"window":e.windowNumber,"flags":e.modifierFlags.rawValue,"window_x":e.locationInWindow.x,"window_y":e.locationInWindow.y]
            if let cg=e.cgEvent{d["source_pid"]=cg.getIntegerValueField(.eventSourceUnixProcessID);d["target_pid"]=cg.getIntegerValueField(.eventTargetUnixProcessID);d["window_91"]=cg.getIntegerValueField(.mouseEventWindowUnderMousePointer);d["window_92"]=cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)}
            if e.type == .keyDown{d["characters"]=e.characters ?? ""};log("input",d)
        }
        super.sendEvent(e)
        if e.type == .keyDown {let editor=NSApp.keyWindow?.firstResponder as? NSTextView;log("key_result",["characters":e.characters ?? "","active":NSApp.isActive,"key_window":NSApp.keyWindow?.windowNumber ?? 0,"selection_location":editor?.selectedRange().location ?? -1,"selection_length":editor?.selectedRange().length ?? -1])}
    }
}
class Button:NSButton{
    override func accessibilityPerformPress()->Bool{log("ax_press");return super.accessibilityPerformPress()}
}
class Surface:NSView{
    override func draw(_ r:NSRect){(foreground ? NSColor(calibratedRed:0.02,green:0.8,blue:0.1,alpha:1):NSColor(calibratedRed:0.9,green:0.03,blue:0.03,alpha:1)).setFill();bounds.fill()}
    override func mouseDown(with e:NSEvent){log("surface_down")}
    override func mouseDragged(with e:NSEvent){log("surface_drag")}
    override func mouseUp(with e:NSEvent){log("surface_up")}
}
class Delegate:NSObject,NSApplicationDelegate,NSTextFieldDelegate{
    var secondary:NSWindow?
    var window:NSWindow!;var text:NSTextField!;var counter:NSTextField!;var count=0;var timer:Timer?
    func applicationDidFinishLaunching(_ n:Notification){
        FileManager.default.createFile(atPath:root+"/"+role+".jsonl",contents:Data())
        window=NSWindow(contentRect:NSRect(x:100,y:NSScreen.screens[0].frame.maxY-700,width:900,height:600),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false);window.title="DSH Background Test \(role)"
        let surface=Surface(frame:NSRect(x:0,y:0,width:900,height:600));window.contentView=surface
        let title=NSTextField(labelWithString:foreground ? "DSH test witness, green":"DSH independent driver test, red");title.frame=NSRect(x:40,y:520,width:800,height:40);title.font=NSFont.boldSystemFont(ofSize:26);surface.addSubview(title)
        counter=NSTextField(labelWithString:"Count: 0");counter.frame=NSRect(x:40,y:470,width:400,height:30);surface.addSubview(counter)
        let button=Button(title:"Increment test counter",target:self,action:#selector(increment));button.frame=NSRect(x:40,y:400,width:300,height:45);surface.addSubview(button)
        text=NSTextField(frame:NSRect(x:40,y:300,width:700,height:45));text.placeholderString="Unicode test field";text.delegate=self;surface.addSubview(text)
        let secure=NSSecureTextField(frame:NSRect(x:40,y:240,width:300,height:35));secure.placeholderString="Secure test field";surface.addSubview(secure)
        let area=NSTextField(labelWithString:"Empty bottom area receives coordinate clicks and drags");area.frame=NSRect(x:40,y:170,width:800,height:30);surface.addSubview(area)
        let menu=NSMenu();let appItem=NSMenuItem();appItem.submenu=NSMenu(title:"Fixture");menu.addItem(appItem);let editItem=NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");menu.addItem(editItem)
        let edit=NSMenu(title:"Edit");editItem.submenu=edit;edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a");edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c");NSApp.mainMenu=menu
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
        if foreground{NSApp.activate(ignoringOtherApps:true)}else{window.orderBack(nil)}
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification]{NotificationCenter.default.addObserver(forName:name,object:nil,queue:nil){n in log("notification",["name":n.name.rawValue])}}
        log("ready",["pid":ProcessInfo.processInfo.processIdentifier,"window_id":window.windowNumber])
        timer=Timer.scheduledTimer(withTimeInterval:0.03,repeats:true){_ in
            let p=root+"/"+role+".command";if let command=try? String(contentsOfFile:p,encoding:.utf8),!command.isEmpty{try? "".write(toFile:p,atomically:true,encoding:.utf8)
                log("command_begin",["command":command,"window_id":self.window.windowNumber])
                if command=="second_window" {let w=NSWindow(contentRect:NSRect(x:150,y:200,width:400,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title="DSH second window";w.isReleasedWhenClosed=false;self.secondary=w;w.makeKeyAndOrderFront(nil);log("second_ready",["window_id":w.windowNumber])}
                if command=="close_second" {self.secondary?.close();self.secondary=nil}
                if command=="minimize"{self.window.miniaturize(nil)}
                if command=="restore"{self.window.deminiaturize(nil);self.window.orderBack(nil);log("shown",["window_id":self.window.windowNumber])}
                if command=="hide"{self.window.orderOut(nil);log("hidden")}
                if command=="activate"{NSApp.activate(ignoringOtherApps:true);self.window.makeKeyAndOrderFront(nil)}
                if command=="move"{self.window.setFrameOrigin(NSPoint(x:160,y:self.window.frame.minY))}
                if command=="quit"{NSApp.terminate(nil)}
                log("command_end",["command":command,"window_id":self.window.windowNumber])
            }
        }
    }
    @objc func increment(){count += 1;counter.stringValue="Count: \(count)";log("button",["count":count])}
    func controlTextDidChange(_ n:Notification){log("text",["value":text.stringValue])}
}
let app=App.shared;app.setActivationPolicy(.regular);let delegate=Delegate();app.delegate=delegate;app.run()
