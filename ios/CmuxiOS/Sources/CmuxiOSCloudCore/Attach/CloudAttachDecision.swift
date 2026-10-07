import CmuxiOSFeatureKit

public enum CloudAttachDecision: Hashable, Sendable {
    case ready(CloudAttachPlan)
    /// The VM is known but cannot answer a link hello until a person resumes it.
    case resumeRequired(CloudMachineStatus)
}
