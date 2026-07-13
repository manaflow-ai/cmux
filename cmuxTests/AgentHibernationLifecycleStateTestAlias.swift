#if canImport(cmux_DEV)
@testable import cmux_DEV
typealias AgentHibernationLifecycleState = cmux_DEV.AgentHibernationLifecycleState
#elseif canImport(cmux)
@testable import cmux
typealias AgentHibernationLifecycleState = cmux.AgentHibernationLifecycleState
#endif
