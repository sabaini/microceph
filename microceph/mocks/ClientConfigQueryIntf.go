// Code generated by mockery v2.30.10. DO NOT EDIT.

package mocks

import (
	context "context"

	database "github.com/canonical/microceph/microceph/database"
	state "github.com/canonical/microcluster/v2/state"
	mock "github.com/stretchr/testify/mock"
)

// ClientConfigQueryIntf is an autogenerated mock type for the ClientConfigQueryIntf type
type ClientConfigQueryIntf struct {
	mock.Mock
}

// AddNew provides a mock function with given fields: s, key, value, host
func (_m *ClientConfigQueryIntf) AddNew(ctx context.Context, s state.State, key string, value string, host string) error {
	ret := _m.Called(s, key, value, host)

	var r0 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string, string, string) error); ok {
		r0 = rf(ctx, s, key, value, host)
	} else {
		r0 = ret.Error(0)
	}

	return r0
}

// GetAll provides a mock function with given fields: s
func (_m *ClientConfigQueryIntf) GetAll(ctx context.Context, s state.State) (database.ClientConfigItems, error) {
	ret := _m.Called(s)

	var r0 database.ClientConfigItems
	var r1 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State) (database.ClientConfigItems, error)); ok {
		return rf(ctx, s)
	}
	if rf, ok := ret.Get(0).(func(context.Context, state.State) database.ClientConfigItems); ok {
		r0 = rf(ctx, s)
	} else {
		if ret.Get(0) != nil {
			r0 = ret.Get(0).(database.ClientConfigItems)
		}
	}

	if rf, ok := ret.Get(1).(func(context.Context, state.State) error); ok {
		r1 = rf(ctx, s)
	} else {
		r1 = ret.Error(1)
	}

	return r0, r1
}

// GetAllForHost provides a mock function with given fields: s, host
func (_m *ClientConfigQueryIntf) GetAllForHost(ctx context.Context, s state.State, host string) (database.ClientConfigItems, error) {
	ret := _m.Called(s, host)

	var r0 database.ClientConfigItems
	var r1 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string) (database.ClientConfigItems, error)); ok {
		return rf(ctx, s, host)
	}
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string) database.ClientConfigItems); ok {
		r0 = rf(ctx, s, host)
	} else {
		if ret.Get(0) != nil {
			r0 = ret.Get(0).(database.ClientConfigItems)
		}
	}

	if rf, ok := ret.Get(1).(func(context.Context, state.State, string) error); ok {
		r1 = rf(ctx, s, host)
	} else {
		r1 = ret.Error(1)
	}

	return r0, r1
}

// GetAllForKey provides a mock function with given fields: s, key
func (_m *ClientConfigQueryIntf) GetAllForKey(ctx context.Context, s state.State, key string) (database.ClientConfigItems, error) {
	ret := _m.Called(s, key)

	var r0 database.ClientConfigItems
	var r1 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string) (database.ClientConfigItems, error)); ok {
		return rf(ctx, s, key)
	}
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string) database.ClientConfigItems); ok {
		r0 = rf(ctx, s, key)
	} else {
		if ret.Get(0) != nil {
			r0 = ret.Get(0).(database.ClientConfigItems)
		}
	}

	if rf, ok := ret.Get(1).(func(context.Context, state.State, string) error); ok {
		r1 = rf(ctx, s, key)
	} else {
		r1 = ret.Error(1)
	}

	return r0, r1
}

// GetAllForKeyAndHost provides a mock function with given fields: s, key, host
func (_m *ClientConfigQueryIntf) GetAllForKeyAndHost(ctx context.Context, s state.State, key string, host string) (database.ClientConfigItems, error) {
	ret := _m.Called(s, key, host)

	var r0 database.ClientConfigItems
	var r1 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string, string) (database.ClientConfigItems, error)); ok {
		return rf(ctx, s, key, host)
	}
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string, string) database.ClientConfigItems); ok {
		r0 = rf(ctx, s, key, host)
	} else {
		if ret.Get(0) != nil {
			r0 = ret.Get(0).(database.ClientConfigItems)
		}
	}

	if rf, ok := ret.Get(1).(func(context.Context, state.State, string, string) error); ok {
		r1 = rf(ctx, s, key, host)
	} else {
		r1 = ret.Error(1)
	}

	return r0, r1
}

// RemoveAllForKey provides a mock function with given fields: s, key
func (_m *ClientConfigQueryIntf) RemoveAllForKey(ctx context.Context, s state.State, key string) error {
	ret := _m.Called(s, key)

	var r0 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string) error); ok {
		r0 = rf(ctx, s, key)
	} else {
		r0 = ret.Error(0)
	}

	return r0
}

// RemoveOneForKeyAndHost provides a mock function with given fields: s, key, host
func (_m *ClientConfigQueryIntf) RemoveOneForKeyAndHost(ctx context.Context, s state.State, key string, host string) error {
	ret := _m.Called(s, key, host)

	var r0 error
	if rf, ok := ret.Get(0).(func(context.Context, state.State, string, string) error); ok {
		r0 = rf(ctx, s, key, host)
	} else {
		r0 = ret.Error(0)
	}

	return r0
}

// NewClientConfigQueryIntf creates a new instance of ClientConfigQueryIntf. It also registers a testing interface on the mock and a cleanup function to assert the mocks expectations.
// The first argument is typically a *testing.T value.
func NewClientConfigQueryIntf(t interface {
	mock.TestingT
	Cleanup(func())
}) *ClientConfigQueryIntf {
	mock := &ClientConfigQueryIntf{}
	mock.Mock.Test(t)

	t.Cleanup(func() { mock.AssertExpectations(t) })

	return mock
}
