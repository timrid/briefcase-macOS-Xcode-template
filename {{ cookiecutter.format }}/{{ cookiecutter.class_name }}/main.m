//
//  main.m
//  A main module for starting Python projects on macOS.
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <Python/Python.h>
#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>

// A global indicator
char *debug_mode;

NSString * format_traceback(PyObject *, PyObject *, PyObject *);
{% if cookiecutter.console_app %}
void info_log(NSString *format, ...);
void debug_log(NSString *format, ...);
{% else %}
#define info_log(...) NSLog(__VA_ARGS__)
#define debug_log(...) if (debug_mode) NSLog(__VA_ARGS__)
{% endif %}
NSBundle *get_main_bundle(void);
void setup_stdout(NSBundle *);
void crash_dialog(NSString *);

int main(int argc, char *argv[]) {
    int ret = 0;
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;
    NSBundle *mainBundle;
    NSString *resourcePath;
    NSString *frameworksPath;
    NSString *python_tag;
    NSString *python_home;
    NSString *app_module_name;
    NSString *path;
    NSString *traceback_str;
    wchar_t *wtmp_str;
    wchar_t *app_packages_path_str;
    const char *app_module_str;
    PyObject *app_packages_path;
    PyObject *app_module;
    PyObject *module;
    PyObject *module_attr;
    PyObject *method_args;
    PyObject *result;
    PyObject *exc_type;
    PyObject *exc_value;
    PyObject *exc_traceback;
    PyObject *systemExit_code;

    @autoreleasepool {
        // Set the global debug state based on the runtime environment
        debug_mode = getenv("BRIEFCASE_DEBUG");

        // Set the resource path for the app
        mainBundle = get_main_bundle();
        resourcePath = [mainBundle resourcePath];
        frameworksPath = [mainBundle privateFrameworksPath];

        // Generate an isolated Python configuration.
        debug_log(@"Configuring isolated Python...");
        PyPreConfig_InitIsolatedConfig(&preconfig);
        PyConfig_InitIsolatedConfig(&config);

        // Configure the Python interpreter:
        // Enforce UTF-8 encoding for stderr, stdout, file-system encoding and locale.
        // See https://docs.python.org/3/library/os.html#python-utf-8-mode.
        preconfig.utf8_mode = 1;
        // Don't buffer stdio. We want output to appears in the log immediately
        config.buffered_stdio = 0;
        // Don't write bytecode; we can't modify the app bundle
        // after it has been signed.
        config.write_bytecode = 0;
        // Isolated apps need to set the full PYTHONPATH manually.
        config.module_search_paths_set = 1;
        // Enable verbose logging for debug purposes
        // config.verbose = 1;

        debug_log(@"Pre-initializing Python runtime...");
        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to pre-initialize Python interpreter: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // Set the home for the Python interpreter
        python_tag = @"{{ cookiecutter.python_version|py_tag }}";
        python_home = [NSString stringWithFormat:@"%@/Python.framework/Versions/%@", frameworksPath, python_tag, nil];
        debug_log(@"PythonHome: %@", python_home);
        wtmp_str = Py_DecodeLocale([python_home UTF8String], NULL);
        status = PyConfig_SetString(&config, &config.home, wtmp_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to set PYTHONHOME: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }
        PyMem_RawFree(wtmp_str);

        // Determine the app module name. Look for the BRIEFCASE_MAIN_MODULE
        // environment variable first; if that exists, we're probably in test
        // mode. If it doesn't exist, fall back to the MainModule key in the
        // main bundle.
        app_module_str = getenv("BRIEFCASE_MAIN_MODULE");
        if (app_module_str) {
            app_module_name = [[NSString alloc] initWithUTF8String:app_module_str];
        } else {
            app_module_name = [mainBundle objectForInfoDictionaryKey:@"MainModule"];
            if (app_module_name == NULL) {
                debug_log(@"Unable to identify app module name.");
            }
            app_module_str = [app_module_name UTF8String];
        }
        status = PyConfig_SetBytesString(&config, &config.run_module, app_module_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to set app module name: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // Read the site config
        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to read site config: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        // Set the full module path. This includes the stdlib, site-packages, and app code.
        debug_log(@"PYTHONPATH:");

        // The unpacked form of the stdlib
        path = [NSString stringWithFormat:@"%@/lib/python%@", python_home, python_tag, nil];
        debug_log(@"- %@", path);
        wtmp_str = Py_DecodeLocale([path UTF8String], NULL);
        status = PyWideStringList_Append(&config.module_search_paths, wtmp_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to set unpacked form of stdlib path: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }
        PyMem_RawFree(wtmp_str);

        // Add the stdlib binary modules path
        path = [NSString stringWithFormat:@"%@/lib/python%@/lib-dynload", python_home, python_tag, nil];
        debug_log(@"- %@", path);
        wtmp_str = Py_DecodeLocale([path UTF8String], NULL);
        status = PyWideStringList_Append(&config.module_search_paths, wtmp_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to set stdlib binary module path: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }
        PyMem_RawFree(wtmp_str);

        // Add the app path
        path = [NSString stringWithFormat:@"%@/app", resourcePath, nil];
        debug_log(@"- %@", path);
        wtmp_str = Py_DecodeLocale([path UTF8String], NULL);
        status = PyWideStringList_Append(&config.module_search_paths, wtmp_str);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to set app path: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }
        PyMem_RawFree(wtmp_str);

        debug_log(@"Configure argc/argv...");
        status = PyConfig_SetBytesArgv(&config, argc, argv);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to configured argc/argv: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        debug_log(@"Initializing Python runtime...");
        status = Py_InitializeFromConfig(&config);
        if (PyStatus_Exception(status)) {
            crash_dialog([NSString stringWithFormat:@"Unable to initialize Python interpreter: %s", status.err_msg, nil]);
            PyConfig_Clear(&config);
            Py_ExitStatusException(status);
        }

        @try {
            // Set up an stdout/stderr handling that is required
            setup_stdout(mainBundle);


            // Adding the app_packages as site directory.
            //
            // This adds app_packages to sys.path and executes any .pth
            // files in that directory.
            path = [NSString stringWithFormat:@"%@/app_packages", resourcePath, nil];
            app_packages_path_str = Py_DecodeLocale([path UTF8String], NULL);

            debug_log(@"Adding app_packages as site directory: %@", path);

            module = PyImport_ImportModule("site");
            if (module == NULL) {
                crash_dialog(@"Could not import site module");
                exit(-11);
            }

            module_attr = PyObject_GetAttrString(module, "addsitedir");
            if (module_attr == NULL || !PyCallable_Check(module_attr)) {
                crash_dialog(@"Could not access site.addsitedir");
                exit(-12);
            }

            app_packages_path = PyUnicode_FromWideChar(app_packages_path_str, wcslen(app_packages_path_str));
            if (app_packages_path == NULL) {
                crash_dialog(@"Could not convert app_packages path to unicode");
                exit(-13);
            }
            PyMem_RawFree(app_packages_path_str);

            method_args = Py_BuildValue("(O)", app_packages_path);
            if (method_args == NULL) {
                crash_dialog(@"Could not create arguments for site.addsitedir");
                exit(-14);
            }

            result = PyObject_CallObject(module_attr, method_args);
            if (result == NULL) {
                crash_dialog(@"Could not add app_packages directory using site.addsitedir");
                exit(-15);
            }


            // Start the app module.
            //
            // From here to Py_ObjectCall(runmodule...) is effectively
            // a copy of Py_RunMain() (and, more  specifically, the
            // pymain_run_module() method); we need to re-implement it
            // because we need to be able to inspect the error state of
            // the interpreter, not just the return code of the module.
            debug_log(@"Running app module: %@", app_module_name);
            module = PyImport_ImportModule("runpy");
            if (module == NULL) {
                crash_dialog(@"Could not import runpy module");
                exit(-2);
            }

            module_attr = PyObject_GetAttrString(module, "_run_module_as_main");
            if (module_attr == NULL) {
                crash_dialog(@"Could not access runpy._run_module_as_main");
                exit(-3);
            }

            app_module = PyUnicode_FromString(app_module_str);
            if (app_module == NULL) {
                crash_dialog(@"Could not convert module name to unicode");
                exit(-3);
            }

            method_args = Py_BuildValue("(Oi)", app_module, 0);
            if (method_args == NULL) {
                crash_dialog(@"Could not create arguments for runpy._run_module_as_main");
                exit(-4);
            }

            // Print a separator to differentiate Python startup logs from app logs
            debug_log(@"---------------------------------------------------------------------------");

            // Invoke the app module
            result = PyObject_Call(module_attr, method_args, NULL);

            if (result == NULL) {
                // Retrieve the current error state of the interpreter.
                PyErr_Fetch(&exc_type, &exc_value, &exc_traceback);
                PyErr_NormalizeException(&exc_type, &exc_value, &exc_traceback);

                if (exc_traceback == NULL) {
                    crash_dialog(@"Could not retrieve traceback");
                    exit(-5);
                }

                traceback_str = NULL;
                if (PyErr_GivenExceptionMatches(exc_value, PyExc_SystemExit)) {
                    systemExit_code = PyObject_GetAttrString(exc_value, "code");
                    if (systemExit_code == NULL) {
                        traceback_str = @"Could not determine exit code";
                        ret = -10;
                    } else if (systemExit_code == Py_None) {
                        // SystemExit with a code of None; documented as a
                        // return code of 0.
                        ret = 0;
                    } else if (PyLong_Check(systemExit_code)) {
                        // SystemExit with error code
                        ret = (int) PyLong_AsLong(systemExit_code);
                    } else {
                        // Any other SystemExit value - convert to a string, and
                        // use the string as the traceback, and use the
                        // documented SystemExit return value of 1.
                        ret = 1;
                        traceback_str = [NSString stringWithUTF8String:PyUnicode_AsUTF8(PyObject_Str(systemExit_code))];
                    }
                } else {
                    // Non-SystemExit; likely an uncaught exception
                    info_log(@"---------------------------------------------------------------------------");
                    info_log(@"Application quit abnormally!");
                    ret = -6;
                    traceback_str = format_traceback(exc_type, exc_value, exc_traceback);
                }

                if (traceback_str != NULL) {
                    // Display stack trace in the crash dialog.
                    crash_dialog(traceback_str);
                }
            }
        }
        @catch (NSException *exception) {
            crash_dialog([NSString stringWithFormat:@"Python runtime error: %@", [exception reason]]);
            ret = -7;
        }
        @finally {
            Py_Finalize();
        }
    }

    exit(ret);
    return ret;
}

/**
 * Convert a Python traceback object into a user-suitable string, stripping off
 * stack context that comes from this stub binary.
 *
 * If any error occurs processing the traceback, the error message returned
 * will describe the mode of failure.
 */
NSString *format_traceback(PyObject *type, PyObject *value, PyObject *traceback) {
    NSRegularExpression *regex;
    NSString *traceback_str;
    PyObject *traceback_list;
    PyObject *traceback_module;
    PyObject *format_exception;
    PyObject *traceback_unicode;
    PyObject *inner_traceback;

    // Drop the top two stack frames; these are internal
    // wrapper logic, and not in the control of the user.
    for (int i = 0; i < 2; i++) {
        inner_traceback = PyObject_GetAttrString(traceback, "tb_next");
        if (inner_traceback != NULL) {
            traceback = inner_traceback;
        }
    }

    // Format the traceback.
    traceback_module = PyImport_ImportModule("traceback");
    if (traceback_module == NULL) {
        return @"Could not import traceback";
    }

    format_exception = PyObject_GetAttrString(traceback_module, "format_exception");
    if (format_exception && PyCallable_Check(format_exception)) {
        traceback_list = PyObject_CallFunctionObjArgs(format_exception, type, value, traceback, NULL);
    } else {
        return @"Could not find 'format_exception' in 'traceback' module";
    }
    if (traceback_list == NULL) {
        return @"Could not format traceback";
    }

    traceback_unicode = PyUnicode_Join(PyUnicode_FromString(""), traceback_list);
    traceback_str = [NSString stringWithUTF8String:PyUnicode_AsUTF8(PyObject_Str(traceback_unicode))];

    // Take the opportunity to clean up the source path,
    // so paths only refer to the "app local" path.
    regex = [NSRegularExpression regularExpressionWithPattern:@"^  File \"/.*/(.*?).app/Contents/Resources/"
                                                      options:NSRegularExpressionAnchorsMatchLines
                                                        error:nil];
    traceback_str = [regex stringByReplacingMatchesInString:traceback_str
                                                    options:0
                                                      range:NSMakeRange(0, [traceback_str length])
                                               withTemplate:@"  File \"$1.app/Contents/Resources/"];
    return traceback_str;
}

{% if cookiecutter.console_app %}
void info_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    printf("%s\n", [[[NSString alloc] initWithFormat:format arguments:args] UTF8String]);
    va_end(args);
}

void debug_log(NSString *format, ...) {
    if (debug_mode) {
        va_list args;
        va_start(args, format);
        printf("%s\n", [[[NSString alloc] initWithFormat:format arguments:args] UTF8String]);
        va_end(args);
    }
}

/****************************************************************************
 * In a normal macOS app, [NSBundle mainBundle] works as expected. However,
 * the path it generates is based on sys.argv[0], which won't be the same if
 * you symlink to the binary to expose a command line app. Instead, use
 * _NSGetExecutablePath to get the binary path, then construct the bundle
 * path based on the known file structure of the app bundle.
 ****************************************************************************/
NSBundle* get_main_bundle(void) {
    uint32_t path_max = PATH_MAX;
    char binary_path[PATH_MAX];
    char resolved_binary_path[PATH_MAX];
    char *bundle_path;
    NSBundle *mainBundle;

    _NSGetExecutablePath(binary_path, &path_max);
    realpath(binary_path, resolved_binary_path);
    debug_log(@"Binary: %s", resolved_binary_path);
    bundle_path = dirname(dirname(dirname(resolved_binary_path)));
    mainBundle = [NSBundle bundleWithPath:[NSString stringWithCString:bundle_path encoding:NSUTF8StringEncoding]];
    debug_log(@"App Bundle: %@", mainBundle);

    return mainBundle;
}

void setup_stdout(NSBundle *mainBundle) {
}

void crash_dialog(NSString *details) {
    info_log(details);
}

{% else %}

NSBundle* get_main_bundle(void) {
    return [NSBundle mainBundle];
}

void setup_stdout(NSBundle *mainBundle) {
    int ret = 0;
    const char *nslog_script;

    // If the app is running under Xcode 15 or later, we don't need to do anything,
    // as stdout and stderr are automatically captured by the in-IDE console.
    // See https://developer.apple.com/forums/thread/705868 for details.
    if (getenv("IDE_DISABLED_OS_ACTIVITY_DT_MODE")) {
        return;
    }

    // Install the nslog script to redirect stdout/stderr if available.
    // Set the name of the python NSLog bootstrap script
    nslog_script = [
        [mainBundle pathForResource:@"app_packages/nslog"
                                ofType:@"py"] cStringUsingEncoding:NSUTF8StringEncoding];

    if (nslog_script == NULL) {
        info_log(@"No Python NSLog handler found. stdout/stderr will not be captured.");
        info_log(@"To capture stdout/stderr, add 'std-nslog' to your app dependencies.");
    } else {
        debug_log(@"Installing Python NSLog handler...");
        FILE *fd = fopen(nslog_script, "r");
        if (fd == NULL) {
            crash_dialog(@"Unable to open nslog.py");
            exit(-1);
        }

        ret = PyRun_SimpleFileEx(fd, nslog_script, 1);
        fclose(fd);
        if (ret != 0) {
            crash_dialog(@"Unable to install Python NSLog handler");
            exit(ret);
        }
    }
}

/**
 * Construct and display a modal dialog to the user that contains
 * details of an error during application execution (usually a traceback).
 */
void crash_dialog(NSString *details) {
    // Write the error to the log
    NSArray *lines = [details componentsSeparatedByString:@"\n"];
    for (int i = 0; i < [lines count]; i++) {
        NSLog(@"%@", lines[i]);
    }

    // If there's an app module override, we're running in test mode; don't show error dialogs
    if (getenv("BRIEFCASE_MAIN_MODULE")) {
        return;
    }

    // Obtain the app instance (starting it if necessary) so that we can show an error dialog
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    // Create a stack trace dialog
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert setMessageText:@"Application has crashed"];
    [alert setInformativeText:@"An unexpected error occurred. Please see the traceback below for more information."];

    // A multiline text widget in a scroll view to contain the stack trace
    NSScrollView *scroll_panel = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
    [scroll_panel setHasVerticalScroller:true];
    [scroll_panel setHasHorizontalScroller:false];
    [scroll_panel setAutohidesScrollers:false];
    [scroll_panel setBorderType:NSBezelBorder];

    NSTextView *crash_text = [[NSTextView alloc] init];
    [crash_text setEditable:false];
    [crash_text setSelectable:true];
    [crash_text setString:details];
    [crash_text setVerticallyResizable:true];
    [crash_text setHorizontallyResizable:true];
    [crash_text setFont:[NSFont fontWithName:@"Menlo" size:12.0]];

    [scroll_panel setDocumentView:crash_text];
    [alert setAccessoryView:scroll_panel];

    // Show the crash dialog
    [alert runModal];
}

{% endif %}
