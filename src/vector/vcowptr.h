/*
 * Copyright (c) 2018 Samsung Electronics Co., Ltd. All rights reserved.
 *
 * Licensed under the LGPL License, Version 2.1 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.gnu.org/licenses/
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef VCOWPTR_H
#define VCOWPTR_H

#include <assert.h>
#include "vglobal.h"

template <typename T>
class vcow_ptr {
    struct model {
        std::atomic<std::size_t> mRef{1};

        model() = default;

        template <class... Args>
        explicit model(Args&&... args) : mValue(std::forward<Args>(args)...)
        {
        }

        T mValue;
    };
    model* mModel;

public:
    using element_type = T;

    vcow_ptr()
    {
        static model default_s;
        mModel = &default_s;
        ++mModel->mRef;
    }

    ~vcow_ptr()
    {
        if (mModel && (--mModel->mRef == 0)) delete mModel;
    }

    template <class... Args>
    vcow_ptr(Args&&... args) : mModel(new model(std::forward<Args>(args)...))
    {
    }

    vcow_ptr(const vcow_ptr& x) noexcept : mModel(x.mModel)
    {
        assert(mModel);
        ++mModel->mRef;
    }
    vcow_ptr(vcow_ptr&& x) noexcept : mModel(x.mModel)
    {
        assert(mModel);
        x.mModel = nullptr;
    }

    auto operator=(const vcow_ptr& x) noexcept -> vcow_ptr&
    {
        return *this = vcow_ptr(x);
    }

    auto operator=(vcow_ptr&& x) noexcept -> vcow_ptr&
    {
        auto tmp = std::move(x);
        swap(*this, tmp);
        return *this;
    }

    auto operator*() const noexcept -> const element_type& { return read(); }

    auto operator-> () const noexcept -> const element_type* { return &read(); }

    int refCount() const noexcept
    {
        assert(mModel);

        return mModel->mRef;
    }

    bool unique() const noexcept
    {
        assert(mModel);

        return mModel->mRef == 1;
    }

    auto write() -> element_type&
    {
        if (!unique()) *this = vcow_ptr(read());

        return mModel->mValue;
    }

    auto read() const noexcept -> const element_type&
    {
        assert(mModel);

        return mModel->mValue;
    }

    friend inline void swap(vcow_ptr& x, vcow_ptr& y) noexcept
    {
        std::swap(x.mModel, y.mModel);
    }
};

#endif  // VCOWPTR_H
