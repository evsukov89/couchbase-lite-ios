//
//  CBLJSViewCompiler.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 1/4/13.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLJSViewCompiler.h"
#import "CBLJSFunction.h"
#import "CBLView.h"
#import "CBLRevision.h"
#import <JavaScriptCore/JavaScript.h>
#import <JavaScriptCore/JSStringRefCF.h>
#import "Logging.h"


/* NOTE: JavaScriptCore is not a public system framework on iOS, so you'll need to link your iOS app
   with your own copy of it. See <https://github.com/phoboslab/JavaScriptCore-iOS>. */

/* NOTE: This source file requires ARC. */

@implementation CBLJSViewCompiler


// This is a kludge that remembers the emit block passed to the currently active map block.
// It's valid only while a map block is running its JavaScript function.
static
#if !TARGET_OS_IPHONE   /* iOS doesn't support __thread ? */
__thread
#endif
__unsafe_unretained CBLMapEmitBlock sCurrentEmitBlock;


// This is the body of the JavaScript "emit(key,value)" function.
static JSValueRef EmitCallback(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject,
                               size_t argumentCount, const JSValueRef arguments[],
                               JSValueRef* exception)
{
    id key = nil, value = nil;
    if (argumentCount > 0) {
        {
            JSValueRef arg = arguments[0];
            JSValueRef exception = NULL;
            JSStringRef jsStr = JSValueCreateJSONString(ctx, arg, 0, &exception);
            if (exception) {
                WarnJSException(ctx, @"JS function threw exception", exception);
            }
            else if (jsStr != NULL) {
                key = CFBridgingRelease(JSStringCopyCFString(NULL, jsStr));
                JSStringRelease(jsStr);
            }
            else {
                LogTo(JS, @"could not convert to JSON, using null as emit key: %@", JSValueToNSString(ctx, arg));
            }
        }
        
        if (argumentCount > 1) {
            JSValueRef arg = arguments[1];
            JSValueRef exception = NULL;
            JSStringRef jsStr = JSValueCreateJSONString(ctx, arg, 0, &exception);
            if (exception) {
                WarnJSException(ctx, @"JS function threw exception", exception);
            }
            else if (jsStr != NULL) {
                value = CFBridgingRelease(JSStringCopyCFString(NULL, jsStr));
                JSStringRelease(jsStr);
            }
            else {
                LogTo(JS, @"could not convert to JSON, using null as emit value: %@", JSValueToNSString(ctx, arg));
            }
        }
    }
    sCurrentEmitBlock(key, value);
    return JSValueMakeUndefined(ctx);
}

// This is the body of the JavaScript "emit_fts(key,value)" function.
static JSValueRef EmitFTSCallback(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject,
                                  size_t argumentCount, const JSValueRef arguments[],
                                  JSValueRef* exception)
{
    id key = nil, value = nil;
    if (argumentCount > 0) {
        {
            JSValueRef arg = arguments[0];
            NSObject* obj = JSValueToNSObject(ctx, arg);
            if ([obj isKindOfClass:[NSString class]]) {
                key = obj;
            } else if ([obj respondsToSelector:@selector(stringValue)]) {
                key = [obj performSelector:@selector(stringValue)];
            } else {
                key = [NSString stringWithFormat:@"%@",obj];
            }
        }
        
        if (argumentCount > 1) {
            JSValueRef arg = arguments[1];
            JSValueRef exception = NULL;
            JSStringRef jsStr = JSValueCreateJSONString(ctx, arg, 0, &exception);
            if (exception) {
                WarnJSException(ctx, @"JS function threw exception", exception);
            }
            else if (jsStr != NULL) {
                value = CFBridgingRelease(JSStringCopyCFString(NULL, jsStr));
                JSStringRelease(jsStr);
            }
            else {
                LogTo(JS, @"could not convert to JSON, using null as emit value: %@", JSValueToNSString(ctx, arg));
            }
        }
    }
    sCurrentEmitBlock(CBLTextKey(key), value);
    return JSValueMakeUndefined(ctx);
}


- (instancetype) init {
    self = [super init];
    if (self) {
        JSGlobalContextRef context = self.context;
        {
        // Install the "emit" function in the context's namespace:
        JSStringRef name = JSStringCreateWithCFString(CFSTR("emit"));
        JSObjectRef fn = JSObjectMakeFunctionWithCallback(context, name, &EmitCallback);
        JSObjectSetProperty(context, JSContextGetGlobalObject(context),
                            name, fn,
                            kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete,
                            NULL);
        JSStringRelease(name);
        }
        
        {
        // Install the "emit_fts" function in the context's namespace:
        JSStringRef name = JSStringCreateWithCFString(CFSTR("emit_fts"));
        JSObjectRef fn = JSObjectMakeFunctionWithCallback(context, name, &EmitFTSCallback);
        JSObjectSetProperty(context, JSContextGetGlobalObject(context),
                            name, fn,
                            kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete,
                            NULL);
        JSStringRelease(name);
        }
    }
    return self;
}

- (CBLMapBlock) compileMapFunction: (NSString*)mapSource language: (NSString*)language {
    return [self compileMapFunction: mapSource language: language userInfo: nil];
}

- (CBLMapBlock) compileMapFunction: (NSString*)mapSource language: (NSString*)language userInfo: (NSDictionary*)userInfo {
    if (![language isEqualToString: @"javascript"])
        return nil;

    // Compile the function:
    CBLJSFunction* fn = [[CBLJSFunction alloc] initWithCompiler: self
                                                   sourceCode: mapSource
                                                   paramNames: @[@"doc"]
                                               requireContext: userInfo];
    if (!fn)
        return nil;

    // Return the CBLMapBlock; the code inside will be called when CouchbaseLite wants to run the map fn:
    CBLMapBlock mapBlock = ^(NSDictionary* doc, CBLMapEmitBlock emit) {
        sCurrentEmitBlock = emit;
        [fn call: doc];
        sCurrentEmitBlock = nil;
    };
    return [mapBlock copy];
}

- (CBLReduceBlock) compileReduceFunction: (NSString*)reduceSource language: (NSString*)language {
    return [self compileReduceFunction: reduceSource language: language userInfo: nil];
}

- (CBLReduceBlock) compileReduceFunction: (NSString*)reduceSource language: (NSString*)language userInfo: (NSDictionary*)userInfo {
    if (![language isEqualToString: @"javascript"])
        return nil;
    
    // i shall not be burned for this
    NSArray* paramNames = @[@"keys", @"values", @"rereduce"];
    if ([reduceSource isEqual:@"_sum"])
        reduceSource = @"function(keys, values, rereduce) { return sum(values); }";
    else if ([reduceSource isEqual:@"_count"])
        reduceSource = @"function(keys, values, rereduce) { if (rereduce) { return sum(values); } else { return values.length; } }";
    else if ([reduceSource isEqual:@"_stats"]) {
        reduceSource = @"function(e,t,n){if(n){return{sum:t.reduce(function(e,t){return e+t.sum},0),min:t.reduce(function(e,t){return Math.min(e,t.min)},Infinity),max:t.reduce(function(e,t){return Math.max(e,t.max)},-Infinity),count:t.reduce(function(e,t){return e+t.count},0),sumsqr:t.reduce(function(e,t){return e+t.sumsqr},0)}}else{return{sum:sum(t),min:Math.min.apply(null,t),max:Math.max.apply(null,t),count:t.length,sumsqr:function(){var e=0;t.forEach(function(t){e+=t*t});return e}()}}}";
        paramNames = @[@"e", @"t", @"n"];
    }
    
    // Compile the function:
    CBLJSFunction* fn = [[CBLJSFunction alloc] initWithCompiler: self
                                                     sourceCode: reduceSource
                                                     paramNames: paramNames
                                                 requireContext: userInfo];
    if (!fn)
        return nil;

    // Return the CBLReduceBlock; the code inside will be called when CouchbaseLite wants to reduce:
    CBLReduceBlock reduceBlock = ^id(NSArray* keys, NSArray* values, BOOL rereduce) {
        JSValueRef result = [fn call: keys, values, @(rereduce)];
        return JSValueToNSObject/*ValueToID*/(self.context, result);
    };
    return [reduceBlock copy];
}


@end

