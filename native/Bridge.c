#include "Bridge.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
static int32_t (*window_id)(AXUIElementRef,uint32_t*);
static void (*event_location)(CGEventRef,CGPoint);
static int32_t (*key_focus)(ProcessSerialNumber*,uint8_t*);
static void init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ax=dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",RTLD_LAZY);
        void *cg=dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",RTLD_LAZY);
        window_id=dlsym(ax,"_AXUIElementGetWindow");
        event_location=dlsym(cg,"CGEventSetWindowLocation");
        key_focus=dlsym(cg,"CPSGetKeyFocusProcess");
        uint32_t (*connection)(void)=dlsym(cg,"CGSMainConnectionID");
        if(connection) connection();
    });
}
int32_t dsh_window_id(AXUIElementRef element,uint32_t *window) {init();return window_id?window_id(element,window):-25200;}
bool dsh_set_event_window_location(CGEventRef event,CGPoint point) {init();if(!event_location)return false;event_location(event,point);return true;}
int32_t dsh_key_focus_pid(pid_t *pid) {init();if(!key_focus)return -1;ProcessSerialNumber psn={0,0};uint8_t flag=0;int32_t status=key_focus(&psn,&flag);if(status)return status;return GetProcessPID(&psn,pid);}
bool dsh_has_window_binding(void){init();return window_id!=NULL;}
bool dsh_has_event_location(void){init();return event_location!=NULL;}
