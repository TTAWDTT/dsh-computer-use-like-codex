#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
int32_t dsh_window_id(AXUIElementRef element, uint32_t *window);
bool dsh_set_event_window_location(CGEventRef event, CGPoint point);
int32_t dsh_key_focus_pid(pid_t *pid);
bool dsh_has_window_binding(void);
bool dsh_has_event_location(void);
