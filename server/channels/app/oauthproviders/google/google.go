// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

package oauthgoogle

import (
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/shared/mlog"
	"github.com/mattermost/mattermost/server/public/shared/request"
	"github.com/mattermost/mattermost/server/v8/einterfaces"
)

type GoogleProvider struct{}

type googleName struct {
	DisplayName string `json:"displayName"`
	FamilyName  string `json:"familyName"`
	GivenName   string `json:"givenName"`
	Metadata    struct {
		Primary bool `json:"primary"`
	} `json:"metadata"`
}

type googleEmail struct {
	Value    string `json:"value"`
	Metadata struct {
		Primary bool `json:"primary"`
	} `json:"metadata"`
}

// GoogleUser represents the relevant subset of the Google People API v1 response.
type GoogleUser struct {
	ResourceName   string        `json:"resourceName"` // e.g. "people/1234567890"
	Names          []googleName  `json:"names"`
	EmailAddresses []googleEmail `json:"emailAddresses"`
}

func init() {
	provider := &GoogleProvider{}
	einterfaces.RegisterOAuthProvider(model.ServiceGoogle, provider)
}

func googleUserFromJSON(data io.Reader) (*GoogleUser, error) {
	var gu GoogleUser
	if err := json.NewDecoder(data).Decode(&gu); err != nil {
		return nil, err
	}
	return &gu, nil
}

func (gu *GoogleUser) IsValid() error {
	if gu.ResourceName == "" {
		return errors.New("google user resource name cannot be empty")
	}
	if gu.primaryEmail() == "" {
		return errors.New("google user email cannot be empty")
	}
	return nil
}

func (gu *GoogleUser) authData() string {
	return strings.TrimPrefix(gu.ResourceName, "people/")
}

func (gu *GoogleUser) primaryEmail() string {
	for _, e := range gu.EmailAddresses {
		if e.Metadata.Primary {
			return e.Value
		}
	}
	if len(gu.EmailAddresses) > 0 {
		return gu.EmailAddresses[0].Value
	}
	return ""
}

func (gu *GoogleUser) primaryName() *googleName {
	for i := range gu.Names {
		if gu.Names[i].Metadata.Primary {
			return &gu.Names[i]
		}
	}
	if len(gu.Names) > 0 {
		return &gu.Names[0]
	}
	return nil
}

func userFromGoogleUser(logger mlog.LoggerIFace, gu *GoogleUser) *model.User {
	user := &model.User{}

	email := gu.primaryEmail()
	user.Email = strings.ToLower(email)

	parts := strings.Split(email, "@")
	user.Username = model.CleanUsername(logger, parts[0])

	if n := gu.primaryName(); n != nil {
		user.FirstName = n.GivenName
		user.LastName = n.FamilyName
		if user.FirstName == "" && user.LastName == "" {
			split := strings.SplitN(n.DisplayName, " ", 2)
			user.FirstName = split[0]
			if len(split) == 2 {
				user.LastName = split[1]
			}
		}
	}

	authData := gu.authData()
	user.AuthData = &authData
	user.AuthService = model.ServiceGoogle

	return user
}

func (gp *GoogleProvider) GetUserFromJSON(rctx request.CTX, data io.Reader, _ *model.User, _ *model.SSOSettings) (*model.User, error) {
	gu, err := googleUserFromJSON(data)
	if err != nil {
		return nil, err
	}
	if err = gu.IsValid(); err != nil {
		return nil, err
	}
	return userFromGoogleUser(rctx.Logger(), gu), nil
}

func (gp *GoogleProvider) GetSSOSettings(_ request.CTX, config *model.Config, _ string) (*model.SSOSettings, error) {
	return &config.GoogleSettings, nil
}

func (gp *GoogleProvider) GetUserFromIdToken(_ request.CTX, _ string) (*model.User, error) {
	return nil, nil
}

func (gp *GoogleProvider) IsSameUser(_ request.CTX, dbUser, oAuthUser *model.User) bool {
	return dbUser.AuthData != nil && oAuthUser.AuthData != nil && *dbUser.AuthData == *oAuthUser.AuthData
}
