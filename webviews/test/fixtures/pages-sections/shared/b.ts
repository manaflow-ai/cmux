// Used by gamma's two sections only. Its state is one per document: both sections count on it.
const state = { count: 0 };
export const b = () => ++state.count;
