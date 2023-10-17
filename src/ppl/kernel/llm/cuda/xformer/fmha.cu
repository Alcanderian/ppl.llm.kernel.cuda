
#include "fmha.h"

#include "autogen/cutlassF.h"

#include <cuda_fp16.h>
#include <cmath>

namespace ppl { namespace kernel { namespace llm { namespace cuda { namespace xformer {

ppl::common::RetCode fmha(
    const cudaStream_t stream,
    const cudaDeviceProp& device_prop,
    const ppl::common::datatype_t datatype,
    const void* query,
    const void* key,
    const void* value,
    const void* optional_attn_mask,
    const void* optional_seqstart_q, // (B + 1)
    const void* optional_seqstart_k, // (B + 1)
    const int64_t batch,
    const int64_t query_stride_b, // 0 if dynamic batch
    const int64_t query_stride_s,
    const int64_t query_stride_h,
    const int64_t key_stride_b, // 0 if dynamic batch
    const int64_t key_stride_s,
    const int64_t key_stride_h,
    const int64_t value_stride_b, // 0 if dynamic batch
    const int64_t value_stride_s,
    const int64_t value_stride_h,
    const int64_t mask_stride_b, // 0 if dynamic batch
    const int64_t mask_stride_s,
    const int64_t mask_stride_h,
    const int64_t output_stride_s,
    const int64_t max_seqlen,
    const int64_t max_kvlen, // unused if dynamic batch
    const int64_t num_heads,
    const int64_t num_kv_heads,
    const int64_t head_dim,
    const int64_t custom_mask_type,
    const double attn_scale,
    void* output)
{
    if (datatype != ppl::common::DATATYPE_FLOAT16) {
        LOG(ERROR) << "only support fp16";
        return ppl::common::RC_UNSUPPORTED;
    }

    const int compute_capability = device_prop.major * 10 + device_prop.minor;
    bool kernel_launched = false;
    const char* kernel_miss_reason = nullptr;
    const auto max_shmem = device_prop.sharedMemPerBlockOptin;

    // launchKernel lambda func
    auto launch_kernel = [&](auto _k, auto kernel_fn) { // _k is struct AttentionKernel in kernel_forward.h
        using Kernel = decltype(_k);
        using scalar_t = typename Kernel::scalar_t;
        (void)_k;

        if (kernel_launched) {
            kernel_miss_reason = "kernel launched";
            return;
        }

        if (!Kernel::kSupportsBias && (optional_attn_mask != nullptr)) {
            kernel_miss_reason = "xformer kernel does not support bias";
            return;
        }

        if (Kernel::kSingleValueIteration && Kernel::kKeysPerBlock < head_dim) {
            kernel_miss_reason = "xformer kernel does not support head_dim";
            return;
        }

        // Uses too much shmem
        size_t smem_bytes = sizeof(typename Kernel::SharedStorage);
        if (smem_bytes > max_shmem) {
            kernel_miss_reason = "xformer kernel use too much shm";
            return;
        }

        typename Kernel::Params p;
        p.query_ptr = (scalar_t*)query;
        p.key_ptr = (scalar_t*)key;
        p.value_ptr = (scalar_t*)value;

        p.logsumexp_ptr = nullptr;
        p.output_accum_ptr = nullptr;

        p.output_ptr = (typename Kernel::output_t*)output;

        if (optional_seqstart_q != nullptr) {
            p.seqstart_q_ptr = (int64_t*)optional_seqstart_q;
            p.seqstart_k_ptr = (int64_t*)optional_seqstart_k;
        }

        p.num_heads = num_heads;
        p.num_kv_repeats = num_heads / num_kv_heads;
        p.head_dim = head_dim;
        p.head_dim_value = head_dim;
        p.num_queries = max_seqlen;
        p.num_keys = optional_seqstart_q == nullptr ? max_kvlen : 0;
        p.num_batches = batch;
        p.custom_mask_type = custom_mask_type;
        p.seqlen_k_ptr = nullptr;

        if (attn_scale != 0) {
            p.scale = float(attn_scale);
        } else {
            p.scale = float(1.0 / std::sqrt(float(p.head_dim)));
        }

        p.q_strideB = query_stride_b;
        p.k_strideB = key_stride_b;
        p.v_strideB = value_stride_b;

        p.q_strideM = query_stride_s;
        p.k_strideM = key_stride_s;
        p.v_strideM = value_stride_s;

        p.q_strideH = query_stride_h;
        p.k_strideH = key_stride_h;
        p.v_strideH = value_stride_h;

        p.o_strideM = output_stride_s;

        if (optional_attn_mask != nullptr) {
            p.attn_bias_ptr = (scalar_t*)optional_attn_mask;
            p.bias_strideB = mask_stride_b;
            p.bias_strideH = mask_stride_h;
            p.bias_strideM = mask_stride_s;
        }

        p.use_dropout = false;

        if (smem_bytes > 0xc000) {
            auto err = cudaFuncSetAttribute(
                kernel_fn, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_bytes);
            if (err == cudaErrorInvalidValue) {
                kernel_miss_reason = "this GPU does not have enough shared-memory kernel requires";
                return;
            }
        }

        if(!Kernel::check_supported(p)) {
            kernel_miss_reason = "xformer get unsupported param";
            return;
        }

        kernel_fn<<<p.getBlocksGrid(), p.getThreadsGrid(), smem_bytes, stream>>>(p);
        kernel_launched = true;
    };

    dispatch_cutlassF<::cutlass::half_t>(launch_kernel, compute_capability);

    if (!kernel_launched) {
        LOG(ERROR) << "xformer kernel not launched, reason: " << kernel_miss_reason;
        return ppl::common::RC_UNSUPPORTED;
    }

    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        LOG(ERROR) << "CUDA Error: " << cudaGetErrorString(err);
        return ppl::common::RC_DEVICE_RUNTIME_ERROR;
    }

    return ppl::common::RC_SUCCESS;
}

}}}}}