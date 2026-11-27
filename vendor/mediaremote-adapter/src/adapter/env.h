// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#ifndef MEDIAREMOTEADAPTER_ADAPTER_ENV_H
#define MEDIAREMOTEADAPTER_ADAPTER_ENV_H

#import <Foundation/Foundation.h>

NSString *getEnvValue(NSString *name);

NSString *getEnvFuncParam(NSString *func_name, int param_pos,
                          NSString *param_name);
NSString *getEnvFuncParamSafe(NSString *func_name, int param_pos,
                              NSString *param_name);
NSNumber *getEnvFuncParamInt(NSString *func_name, int param_pos,
                             NSString *param_name);
long getEnvFuncParamLongSafe(NSString *func_name, int param_pos,
                             NSString *param_name);
int getEnvFuncParamIntSafe(NSString *func_name, int param_pos,
                           NSString *param_name);

NSString *getEnvOption(NSString *option_name);
NSNumber *getEnvOptionInt(NSString *option_name);

#endif // MEDIAREMOTEADAPTER_ADAPTER_ENV_H
