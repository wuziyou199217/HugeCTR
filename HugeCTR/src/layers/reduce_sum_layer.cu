/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "HugeCTR/include/layers/reduce_sum_layer.hpp"
#include "HugeCTR/include/utils.hpp"
#include "HugeCTR/include/utils.cuh"

#include <algorithm>
#include <functional>

#ifndef NDEBUG
#include <iostream>
#endif
 
namespace HugeCTR {
 
namespace {

template <size_t length, typename T>
__device__ int array_length(T (&arr)[length]) { return length; }

// this kernel can support dims_size=1/2/3
template<typename ...Args>
__global__ void reduce_sum_kernel(const float * input, 
                                  float * output, 
                                  int axis,
                                  Args... args) {
  int in_dims[] = {args...};
  int dims_size = array_length(in_dims);
  float local_sum = 0.0f; 

  if(axis == 0) { // block_num = dim1 * dim2, do dim0 number of elements reduction in one block
    if(dims_size == 1) { // dims_size == 1
      for(int tid = threadIdx.x; tid < in_dims[0]; tid += blockDim.x) {
        local_sum += input[tid];
      }
    }
    else if(dims_size == 2) { // dims_size == 2
      for(int tid = threadIdx.x; tid < in_dims[0]; tid += blockDim.x) {
        local_sum += input[tid * in_dims[1] + blockIdx.x];
      }
    }
    else if(dims_size == 3) { // dims_size == 3
      for(int tid = threadIdx.x; tid < in_dims[0]; tid += blockDim.x) {
        local_sum += input[tid * (in_dims[1] * in_dims[2]) + blockIdx.x];
      }
    }
  }
  else if(axis == 1) { // block_num = dim0 * dim2, do dim1 number of elements reduction in one block
    if(dims_size == 2) { // dims_size == 2
      for(int tid = threadIdx.x; tid < in_dims[1]; tid += blockDim.x) {
        local_sum += input[blockIdx.x * in_dims[1] + tid];
      }
    }
    else if(dims_size == 3) { // dims_size == 3
      for(int tid = threadIdx.x; tid < in_dims[1]; tid += blockDim.x) {
        local_sum += input[blockIdx.x / in_dims[2] * (in_dims[1] * in_dims[2]) 
          + tid * in_dims[2] + blockIdx.x % in_dims[2]];
      }
    }
  }
  else if(axis == 2) { // block_num = dim0 * dim1, do dim2 number of elements reduction in one block
    for(int tid = threadIdx.x; tid < in_dims[2]; tid += blockDim.x) {
      local_sum += input[blockIdx.x * in_dims[2] + tid];
    }
  }

  local_sum = blockReduceSum(local_sum);
  if(threadIdx.x == 0) {
    output[blockIdx.x] = local_sum;
  }
}

template<typename ...Args>
__global__ void reduce_sum_dgrad_kernel(const float * top_grad,
                                        float * dgrad,
                                        int axis,
                                        Args... args) {
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  int in_dims[] = {args...};
  int dims_size = array_length(in_dims);

  if(axis == 0) { 
    if(dims_size == 1) { // dims_size == 1
      if(tid < in_dims[0]) {
        dgrad[tid] = top_grad[0];
      }
    }  
    else if(dims_size == 2) { // dims_size == 2
      if(tid < (in_dims[0] * in_dims[1])) {
        dgrad[tid] = top_grad[tid % in_dims[1]];
      }
    }
    else if(dims_size == 3) { // dims_size == 3
      if(tid < (in_dims[0] * in_dims[1] * in_dims[2])) {
        int dim1_index = tid % (in_dims[1] * in_dims[2]) / in_dims[2];
        int dim2_index = tid % in_dims[2];
        dgrad[tid] = top_grad[dim1_index * in_dims[2] + dim2_index];
      }
    }
  }
  else if(axis == 1) { 
    if(dims_size == 2) { // dims_size == 2
      if(tid < (in_dims[0] * in_dims[1])) {
        dgrad[tid] = top_grad[tid / in_dims[1]];
      }
    }
    else if(dims_size == 3) { // dims_size == 3
      if(tid < (in_dims[0] * in_dims[1] * in_dims[2])) {
        int dim0_index = tid / (in_dims[1] * in_dims[2]);
        int dim2_index = tid % in_dims[2];
        dgrad[tid] = top_grad[dim0_index * in_dims[2] + dim2_index];
      }
    }
  }
  else if(axis == 2) { 
    int dim0_index = tid / (in_dims[1] * in_dims[2]);
    int dim1_index = tid % (in_dims[1] * in_dims[2]) / in_dims[2];
    dgrad[tid] = top_grad[dim0_index * in_dims[1] + dim1_index];
  }
}

} // end of namespace

ReduceSumLayer::ReduceSumLayer(const std::shared_ptr<Tensor<float>>& in_tensor,
                              std::shared_ptr<Tensor<float>>& out_tensor, 
                              const std::shared_ptr<GeneralBuffer<float>>& blobs_buff,
                              int axis,
                              int device_id)
     : Layer(device_id),
     axis_(axis),
     device_id_(device_id) {
  try {
    CudaDeviceContext context(device_id_);
    
    // error input checking 
    auto in_dims = in_tensor->get_dims();
    for(auto i : in_dims) {
      if(i == 0) {
        CK_THROW_(Error_t::WrongInput, "The input dims can not be 0");
      }
    }
    if(axis >= (int)(in_dims.size()) || axis < 0) {
      CK_THROW_(Error_t::WrongInput, "The axis is overflow");
    }

    std::vector<int> out_dims(in_dims.size());
    for(int i = 0; i < (int)(in_dims.size()); i++) {
      if(i == axis) {
        out_dims[i] = 1;
      }
      else {
        out_dims[i] = in_dims[i];
      }
    }

    // HugeCTR can only support dims_size = 2 or 3
    TensorFormat_t out_format;
    if(in_dims.size() == 2) {
      out_format = TensorFormat_t::HW;
    }
    else if(in_dims.size() == 3) {
      out_format = TensorFormat_t::HSW;
    }
    else {
      CK_THROW_(Error_t::WrongInput, "The in_dims.size() must be 2 or 3");
    }
    out_tensor.reset(new Tensor<float>(out_dims, blobs_buff, out_format));
    out_tensors_.emplace_back(out_tensor);
    in_tensors_.emplace_back(in_tensor);

  } catch (const std::runtime_error& rt_err) {
    std::cerr << rt_err.what() << std::endl;
    throw;
  }
}
 
void ReduceSumLayer::fprop(cudaStream_t stream) {
  CudaDeviceContext context(device_id_);

  float* input = in_tensors_[0]->get_ptr();
  float* output = out_tensors_[0]->get_ptr();
  auto in_dims = in_tensors_[0]->get_dims();
  auto out_dims = out_tensors_[0]->get_dims();

  int block_num = 1;
  for(auto dim : out_dims) {
    block_num *= dim;
  }

  dim3 blockSize(256, 1, 1);
  dim3 gridSize(block_num, 1, 1);
  if(in_dims.size() == 1) {
    reduce_sum_kernel<<<gridSize, blockSize, 0, stream>>>(input, output, 
      axis_, in_dims[0]);
  }
  else if (in_dims.size() == 2) {
    reduce_sum_kernel<<<gridSize, blockSize, 0, stream>>>(input, output, 
      axis_, in_dims[0], in_dims[1]);
  }
  else if(in_dims.size() == 3) {
    reduce_sum_kernel<<<gridSize, blockSize, 0, stream>>>(input, output, 
      axis_, in_dims[0], in_dims[1], in_dims[2]);
  }
}
 
void ReduceSumLayer::bprop(cudaStream_t stream) {
  try {
    CudaDeviceContext context(device_id_);

    float* input = in_tensors_[0]->get_ptr();
    float* output = out_tensors_[0]->get_ptr();
    auto in_dims = in_tensors_[0]->get_dims();

    int size = 1;
    for(auto dim : in_dims) {
      size *= dim;
    }

    dim3 blockSize(256, 1, 1);
    dim3 gridSize((size+blockSize.x-1)/blockSize.x, 1, 1);
    if(in_dims.size() == 1) {
      reduce_sum_dgrad_kernel<<<gridSize, blockSize, 0, stream>>>(output, input, 
        axis_, in_dims[0]);
    }
    else if (in_dims.size() == 2) {
      reduce_sum_dgrad_kernel<<<gridSize, blockSize, 0, stream>>>(output, input, 
        axis_, in_dims[0], in_dims[1]);
    }
    else if(in_dims.size() == 3) {
      reduce_sum_dgrad_kernel<<<gridSize, blockSize, 0, stream>>>(output, input, 
        axis_, in_dims[0], in_dims[1], in_dims[2]);
    }

  } catch (const std::runtime_error& rt_err) {
    std::cerr << rt_err.what() << std::endl;
    throw;
  }
}
 
}  // namespace HugeCTR
 